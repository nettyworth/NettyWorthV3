import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, keccak256, toHex } from "viem";

// AssetState enum values matching the contract
const AssetState = {
  Held: 0,
  Listed: 1,
  Loaned: 2,
  Traded: 3,
  InShipment: 4,
  RemovedFromPlatform: 5,
} as const;

const CONTRACT_URI = "ipfs://contract-metadata";
const TOKEN_URI = "ipfs://token/1";

describe("AssetNFT", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [walletAdmin, walletMinter, walletUser, walletUser2] =
    await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const minterAddress = walletMinter.account.address;
  const userAddress = walletUser.account.address;
  const user2Address = walletUser2.account.address;

  // Helper: deploy AssetNFT behind ERC1967Proxy
  async function deployAssetNFT() {
    const impl = await viem.deployContract("AssetNFT");

    const initData = encodeFunctionData({
      abi: impl.abi,
      functionName: "initialize",
      args: [adminAddress, "NettyWorth Assets", "NWA", CONTRACT_URI],
    });

    const proxy = await viem.deployContract("ERC1967ProxyHelper", [
      impl.address,
      initData,
    ]);

    // Return a contract instance pointing to the proxy address but using AssetNFT ABI
    return viem.getContractAt("AssetNFT", proxy.address);
  }

  // Helper: compute keccak256 of a role string
  function roleHash(role: string): `0x${string}` {
    return keccak256(toHex(role));
  }

  const MINTER_ROLE = roleHash("MINTER_ROLE");
  const BURNER_ROLE = roleHash("BURNER_ROLE");
  const STATE_MANAGER_ROLE = roleHash("STATE_MANAGER_ROLE");
  const URI_SETTER_ROLE = roleHash("URI_SETTER_ROLE");

  // =========================================================================
  // Deployment and initialization
  // =========================================================================

  describe("Deployment", async function () {
    it("should initialize with correct name, symbol, contractURI", async function () {
      const nft = await deployAssetNFT();

      assert.equal(await nft.read.name(), "NettyWorth Assets");
      assert.equal(await nft.read.symbol(), "NWA");
      assert.equal(await nft.read.contractURI(), CONTRACT_URI);
    });

    it("should grant all roles to defaultAdmin", async function () {
      const nft = await deployAssetNFT();

      const DEFAULT_ADMIN_ROLE =
        "0x0000000000000000000000000000000000000000000000000000000000000000";

      assert.equal(
        await nft.read.hasRole([DEFAULT_ADMIN_ROLE, adminAddress]),
        true,
      );
      assert.equal(await nft.read.hasRole([MINTER_ROLE, adminAddress]), true);
      assert.equal(await nft.read.hasRole([BURNER_ROLE, adminAddress]), true);
      assert.equal(
        await nft.read.hasRole([STATE_MANAGER_ROLE, adminAddress]),
        true,
      );
      assert.equal(
        await nft.read.hasRole([URI_SETTER_ROLE, adminAddress]),
        true,
      );
    });

    it("should reject initialization with zero address admin", async function () {
      const impl = await viem.deployContract("AssetNFT");
      const initData = encodeFunctionData({
        abi: impl.abi,
        functionName: "initialize",
        args: [
          "0x0000000000000000000000000000000000000000",
          "Test",
          "TST",
          "",
        ],
      });

      await assert.rejects(
        viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]),
      );
    });
  });

  // =========================================================================
  // Role management
  // =========================================================================

  describe("Role management", async function () {
    it("should allow admin to grant MINTER_ROLE and new minter to mint", async function () {
      const nft = await deployAssetNFT();

      // Admin grants minter role to walletMinter
      await nft.write.grantRole([MINTER_ROLE, minterAddress], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.hasRole([MINTER_ROLE, minterAddress]), true);

      // New minter can mint
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletMinter.account,
      });

      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
    });

    it("should reject minting from unauthorized account", async function () {
      const nft = await deployAssetNFT();
      await assert.rejects(
        nft.write.mint([userAddress, 1n, TOKEN_URI], {
          account: walletUser.account,
        }),
      );
    });
  });

  // =========================================================================
  // Minting
  // =========================================================================

  describe("Minting", async function () {
    it("single mint sets owner, tokenURI, and Held state", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });

      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(await nft.read.tokenURI([1n]), TOKEN_URI);
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);
      assert.equal(await nft.read.totalSupply(), 1n);
    });

    it("batch mint sets all tokens and emits BatchMetadataUpdate", async function () {
      const nft = await deployAssetNFT();
      const startBlock = await publicClient.getBlockNumber();

      const recipients = [userAddress, userAddress, userAddress];
      const tokenIds = [10n, 20n, 30n];
      const uris = [TOKEN_URI, TOKEN_URI, TOKEN_URI];

      await nft.write.batchMint([recipients, tokenIds, uris], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.totalSupply(), 3n);
      assert.equal(
        (await nft.read.ownerOf([10n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(
        (await nft.read.ownerOf([20n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(
        (await nft.read.ownerOf([30n])).toLowerCase(),
        userAddress.toLowerCase(),
      );

      const events = await publicClient.getContractEvents({
        address: nft.address,
        abi: nft.abi,
        eventName: "BatchMetadataUpdate",
        fromBlock: startBlock,
        strict: true,
      });

      assert.equal(events.length, 1);
      assert.equal(events[0].args._fromTokenId, 10n);
      assert.equal(events[0].args._toTokenId, 30n);
    });

    it("batch mint reverts when batch is too large (51 items)", async function () {
      const nft = await deployAssetNFT();
      const size = 51;
      const recipients = Array(size).fill(userAddress);
      const tokenIds = Array.from({ length: size }, (_, i) => BigInt(i + 1));
      const uris = Array(size).fill(TOKEN_URI);

      await assert.rejects(
        nft.write.batchMint([recipients, tokenIds, uris], {
          account: walletAdmin.account,
        }),
      );
    });
  });

  // =========================================================================
  // Burning
  // =========================================================================

  describe("Burning", async function () {
    it("should burn a token in Held state and emit MetadataUpdate", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      // Capture block after mint so mint's MetadataUpdate is excluded
      const startBlock = (await publicClient.getBlockNumber()) + 1n;
      await nft.write.burn([1n], { account: walletAdmin.account });

      await assert.rejects(nft.read.ownerOf([1n]));

      const events = await publicClient.getContractEvents({
        address: nft.address,
        abi: nft.abi,
        eventName: "MetadataUpdate",
        fromBlock: startBlock,
        strict: true,
      });
      assert.equal(events.length, 1);
      assert.equal(events[0].args._tokenId, 1n);
    });

    it("should reject burn from non-BURNER_ROLE", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.burn([1n], { account: walletUser.account }),
      );
    });

    it("should reject burn of a Listed token", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      await nft.write.setAssetState([1n, AssetState.Listed], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.burn([1n], { account: walletAdmin.account }),
      );
    });
  });

  // =========================================================================
  // State machine
  // =========================================================================

  describe("State machine", async function () {
    it("full lifecycle: Held → Listed → Held → InShipment → RemovedFromPlatform", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });

      await nft.write.setAssetState([1n, AssetState.Listed], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Listed);

      await nft.write.setAssetState([1n, AssetState.Held], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);

      await nft.write.setAssetState([1n, AssetState.InShipment], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.InShipment);

      await nft.write.setAssetState([1n, AssetState.RemovedFromPlatform], {
        account: walletAdmin.account,
      });
      assert.equal(
        await nft.read.getAssetState([1n]),
        AssetState.RemovedFromPlatform,
      );
    });

    it("should emit AssetStateChanged with correct args", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });

      const startBlock = await publicClient.getBlockNumber();
      await nft.write.setAssetState([1n, AssetState.Listed], {
        account: walletAdmin.account,
      });

      const events = await publicClient.getContractEvents({
        address: nft.address,
        abi: nft.abi,
        eventName: "AssetStateChanged",
        fromBlock: startBlock,
        strict: true,
      });

      assert.equal(events.length, 1);
      assert.equal(events[0].args.tokenId, 1n);
      assert.equal(events[0].args.previousState, AssetState.Held);
      assert.equal(events[0].args.newState, AssetState.Listed);
    });

    it("should reject invalid state transition (Listed → Loaned)", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      await nft.write.setAssetState([1n, AssetState.Listed], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.setAssetState([1n, AssetState.Loaned], {
          account: walletAdmin.account,
        }),
      );
    });

    it("batchSetAssetState updates multiple tokens", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      await nft.write.mint([userAddress, 2n, TOKEN_URI], {
        account: walletAdmin.account,
      });

      await nft.write.batchSetAssetState([[1n, 2n], AssetState.Listed], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.getAssetState([1n]), AssetState.Listed);
      assert.equal(await nft.read.getAssetState([2n]), AssetState.Listed);
    });
  });

  // =========================================================================
  // Transfer restrictions
  // =========================================================================

  describe("Transfer restrictions", async function () {
    it("should allow transfer when state is Held", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });

      await nft.write.transferFrom([userAddress, user2Address, 1n], {
        account: walletUser.account,
      });

      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        user2Address.toLowerCase(),
      );
    });

    it("should reject transfer when state is Listed", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      await nft.write.setAssetState([1n, AssetState.Listed], {
        account: walletAdmin.account,
      });

      await assert.rejects(
        nft.write.transferFrom([userAddress, user2Address, 1n], {
          account: walletUser.account,
        }),
      );
    });
  });

  // =========================================================================
  // Metadata
  // =========================================================================

  describe("Metadata", async function () {
    it("setTokenURI updates URI and emits MetadataUpdate", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      // Capture block after mint so mint's MetadataUpdate is excluded
      const startBlock = (await publicClient.getBlockNumber()) + 1n;
      await nft.write.setTokenURI([1n, "ipfs://updated"], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.tokenURI([1n]), "ipfs://updated");

      const events = await publicClient.getContractEvents({
        address: nft.address,
        abi: nft.abi,
        eventName: "MetadataUpdate",
        fromBlock: startBlock,
        strict: true,
      });
      assert.equal(events.length, 1);
    });

    it("setContractURI updates contractURI and emits ContractURIUpdated", async function () {
      const nft = await deployAssetNFT();
      const startBlock = await publicClient.getBlockNumber();

      await nft.write.setContractURI(["ipfs://new-collection-metadata"], {
        account: walletAdmin.account,
      });

      assert.equal(
        await nft.read.contractURI(),
        "ipfs://new-collection-metadata",
      );

      const events = await publicClient.getContractEvents({
        address: nft.address,
        abi: nft.abi,
        eventName: "ContractURIUpdated",
        fromBlock: startBlock,
        strict: true,
      });
      assert.equal(events.length, 1);
    });

    it("setBaseURI prefixes all tokenURIs", async function () {
      const nft = await deployAssetNFT();
      await nft.write.mint([userAddress, 1n, "metadata/1"], {
        account: walletAdmin.account,
      });
      await nft.write.setBaseURI(["https://api.nettyworth.io/assets/"], {
        account: walletAdmin.account,
      });

      assert.equal(
        await nft.read.tokenURI([1n]),
        "https://api.nettyworth.io/assets/metadata/1",
      );
    });
  });

  // =========================================================================
  // Pause
  // =========================================================================

  describe("Pause", async function () {
    it("pause blocks minting; unpause resumes", async function () {
      const nft = await deployAssetNFT();

      await nft.write.pause({ account: walletAdmin.account });
      assert.equal(await nft.read.paused(), true);

      await assert.rejects(
        nft.write.mint([userAddress, 1n, TOKEN_URI], {
          account: walletAdmin.account,
        }),
      );

      await nft.write.unpause({ account: walletAdmin.account });
      assert.equal(await nft.read.paused(), false);

      await nft.write.mint([userAddress, 1n, TOKEN_URI], {
        account: walletAdmin.account,
      });
      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
    });
  });

  // =========================================================================
  // supportsInterface
  // =========================================================================

  describe("supportsInterface", async function () {
    it("supports ERC721, ERC721Enumerable, ERC4906, and IAccessControl", async function () {
      const nft = await deployAssetNFT();

      assert.equal(await nft.read.supportsInterface(["0x80ac58cd"]), true); // IERC721
      assert.equal(await nft.read.supportsInterface(["0x780e9d63"]), true); // IERC721Enumerable
      assert.equal(await nft.read.supportsInterface(["0x49064906"]), true); // IERC4906
      assert.equal(await nft.read.supportsInterface(["0x7965db0b"]), true); // IAccessControl
    });
  });
});
