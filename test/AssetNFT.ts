import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, toHex, keccak256, concat } from "viem";

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
const FORWARDER = "0x1234567890123456789012345678901234567890" as `0x${string}`;
const ROYALTY_RECEIVER = "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF" as `0x${string}`;
const ROYALTY_FEE = 250n; // 2.5%

describe("AssetNFT", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [walletAdmin, walletMinter, walletUser, walletUser2] =
    await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const minterAddress = walletMinter.account.address;
  const userAddress = walletUser.account.address;
  const user2Address = walletUser2.account.address;

  async function deployAssetNFT() {
    const impl = await viem.deployContract("AssetNFT", [FORWARDER]);

    const initData = encodeFunctionData({
      abi: impl.abi,
      functionName: "initialize",
      args: [adminAddress, "NettyWorth Assets", "NWA", CONTRACT_URI, ROYALTY_RECEIVER, ROYALTY_FEE],
    });

    const proxy = await viem.deployContract("ERC1967ProxyHelper", [
      impl.address,
      initData,
    ]);

    return viem.getContractAt("AssetNFT", proxy.address);
  }

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
      const impl = await viem.deployContract("AssetNFT", [FORWARDER]);
      const initData = encodeFunctionData({
        abi: impl.abi,
        functionName: "initialize",
        args: [
          "0x0000000000000000000000000000000000000000",
          "Test",
          "TST",
          "",
          ROYALTY_RECEIVER,
          ROYALTY_FEE,
        ],
      });

      await assert.rejects(
        viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]),
      );
    });

    it("should set trusted forwarder", async function () {
      const nft = await deployAssetNFT();
      assert.equal(
        (await nft.read.trustedForwarder()).toLowerCase(),
        FORWARDER.toLowerCase(),
      );
      assert.equal(await nft.read.isTrustedForwarder([FORWARDER]), true);
    });

    it("should set default royalty", async function () {
      const nft = await deployAssetNFT();
      const [receiver, amount] = await nft.read.royaltyInfo([1n, 10000n]);
      assert.equal(receiver.toLowerCase(), ROYALTY_RECEIVER.toLowerCase());
      assert.equal(amount, 250n);
    });
  });

  // =========================================================================
  // Role management
  // =========================================================================

  describe("Role management", async function () {
    it("should allow admin to grant MINTER_ROLE and new minter to batchMint", async function () {
      const nft = await deployAssetNFT();

      await nft.write.grantRole([MINTER_ROLE, minterAddress], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.hasRole([MINTER_ROLE, minterAddress]), true);

      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletMinter.account,
      });

      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
    });

    it("should reject batchMint from unauthorized account", async function () {
      const nft = await deployAssetNFT();
      await assert.rejects(
        nft.write.batchMint([[userAddress], [TOKEN_URI]], {
          account: walletUser.account,
        }),
      );
    });
  });

  // =========================================================================
  // Minting
  // =========================================================================

  describe("Minting", async function () {
    it("batchMint sets owner, tokenURI, and Held state", async function () {
      const nft = await deployAssetNFT();

      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });

      // First token gets ID 1
      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(await nft.read.tokenURI([1n]), TOKEN_URI);
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);
      assert.equal(await nft.read.totalSupply(), 1n);
    });

    it("sequential batchMints get IDs 1, 2, 3", async function () {
      const nft = await deployAssetNFT();

      await nft.write.batchMint([[userAddress], [TOKEN_URI]], { account: walletAdmin.account });
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], { account: walletAdmin.account });
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], { account: walletAdmin.account });

      assert.equal(await nft.read.totalSupply(), 3n);
      assert.equal((await nft.read.ownerOf([1n])).toLowerCase(), userAddress.toLowerCase());
      assert.equal((await nft.read.ownerOf([2n])).toLowerCase(), userAddress.toLowerCase());
      assert.equal((await nft.read.ownerOf([3n])).toLowerCase(), userAddress.toLowerCase());
    });

    it("batch mint sets all tokens and emits BatchMetadataUpdate", async function () {
      const nft = await deployAssetNFT();
      const startBlock = await publicClient.getBlockNumber();

      const recipients = [userAddress, userAddress, userAddress];
      const uris = [TOKEN_URI, TOKEN_URI, TOKEN_URI];

      await nft.write.batchMint([recipients, uris], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.totalSupply(), 3n);
      assert.equal(
        (await nft.read.ownerOf([1n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(
        (await nft.read.ownerOf([2n])).toLowerCase(),
        userAddress.toLowerCase(),
      );
      assert.equal(
        (await nft.read.ownerOf([3n])).toLowerCase(),
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
      assert.equal(events[0].args._fromTokenId, 1n);
      assert.equal(events[0].args._toTokenId, 3n);
    });

    it("batch mint reverts when batch is too large (51 items)", async function () {
      const nft = await deployAssetNFT();
      const size = 51;
      const recipients = Array(size).fill(userAddress);
      const uris = Array(size).fill(TOKEN_URI);

      await assert.rejects(
        nft.write.batchMint([recipients, uris], {
          account: walletAdmin.account,
        }),
      );
    });

    it("batch mint reverts on array length mismatch", async function () {
      const nft = await deployAssetNFT();

      await assert.rejects(
        nft.write.batchMint([[userAddress, userAddress], [TOKEN_URI]], {
          account: walletAdmin.account,
        }),
      );
    });
  });

  // =========================================================================
  // Burning
  // =========================================================================

  describe("Burning", async function () {
    it("should batchBurn a token in Held state and emit MetadataUpdate", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      const startBlock = (await publicClient.getBlockNumber()) + 1n;
      await nft.write.batchBurn([[1n]], { account: walletAdmin.account });

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

    it("batchBurn burns multiple tokens in one call", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress, userAddress, userAddress], [TOKEN_URI, TOKEN_URI, TOKEN_URI]], {
        account: walletAdmin.account,
      });

      await nft.write.batchBurn([[1n, 2n, 3n]], { account: walletAdmin.account });

      assert.equal(await nft.read.totalSupply(), 0n);
    });

    it("batchBurn reverts on non-existent token", async function () {
      const nft = await deployAssetNFT();
      await assert.rejects(
        nft.write.batchBurn([[999n]], { account: walletAdmin.account }),
      );
    });

    it("should reject batchBurn from non-BURNER_ROLE", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.batchBurn([[1n]], { account: walletUser.account }),
      );
    });

    it("should reject batchBurn of a Listed token", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await nft.write.batchSetAssetState([[1n], [AssetState.Listed]], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.batchBurn([[1n]], { account: walletAdmin.account }),
      );
    });

    it("batchBurn reverts when batch size exceeds 50", async function () {
      const nft = await deployAssetNFT();
      const ids = Array.from({ length: 51 }, (_, i) => BigInt(i + 1));

      await assert.rejects(
        nft.write.batchBurn([ids], { account: walletAdmin.account }),
      );
    });
  });

  // =========================================================================
  // State machine
  // =========================================================================

  describe("State machine", async function () {
    it("full lifecycle: Held → Listed → Held → InShipment → RemovedFromPlatform", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });

      await nft.write.batchSetAssetState([[1n], [AssetState.Listed]], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Listed);

      await nft.write.batchSetAssetState([[1n], [AssetState.Held]], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);

      await nft.write.batchSetAssetState([[1n], [AssetState.InShipment]], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.InShipment);

      await nft.write.batchSetAssetState([[1n], [AssetState.RemovedFromPlatform]], {
        account: walletAdmin.account,
      });
      assert.equal(
        await nft.read.getAssetState([1n]),
        AssetState.RemovedFromPlatform,
      );
    });

    it("should emit AssetStateChanged with correct args", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });

      const startBlock = await publicClient.getBlockNumber();
      await nft.write.batchSetAssetState([[1n], [AssetState.Listed]], {
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
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await nft.write.batchSetAssetState([[1n], [AssetState.Listed]], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.batchSetAssetState([[1n], [AssetState.Loaned]], {
          account: walletAdmin.account,
        }),
      );
    });

    it("batchSetAssetState updates multiple tokens", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress, userAddress], [TOKEN_URI, TOKEN_URI]], {
        account: walletAdmin.account,
      });

      await nft.write.batchSetAssetState([[1n, 2n], [AssetState.Listed, AssetState.Listed]], {
        account: walletAdmin.account,
      });

      assert.equal(await nft.read.getAssetState([1n]), AssetState.Listed);
      assert.equal(await nft.read.getAssetState([2n]), AssetState.Listed);
    });

    it("batchSetAssetState reverts when too large (51 items)", async function () {
      const nft = await deployAssetNFT();
      const ids = Array.from({ length: 51 }, (_, i) => BigInt(i + 1));

      await assert.rejects(
        nft.write.batchSetAssetState([ids, ids.map(() => AssetState.Listed)], {
          account: walletAdmin.account,
        }),
      );
    });

    it("batchSetAssetState reverts on array length mismatch", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress, userAddress], [TOKEN_URI, TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        nft.write.batchSetAssetState([[1n, 2n], [AssetState.Listed]], {
          account: walletAdmin.account,
        }),
      );
    });

    it("batchSetAssetState applies different states per token", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress, userAddress], [TOKEN_URI, TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await nft.write.batchSetAssetState([[1n, 2n], [AssetState.Listed, AssetState.Loaned]], {
        account: walletAdmin.account,
      });
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Listed);
      assert.equal(await nft.read.getAssetState([2n]), AssetState.Loaned);
    });
  });

  // =========================================================================
  // Transfer restrictions
  // =========================================================================

  describe("Transfer restrictions", async function () {
    it("should allow transfer when state is Held", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
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
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await nft.write.batchSetAssetState([[1n], [AssetState.Listed]], {
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
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
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
      await nft.write.batchMint([[userAddress], ["metadata/1"]], {
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
  // ERC-2981 Royalties
  // =========================================================================

  describe("Royalties", async function () {
    it("returns correct default royalty info", async function () {
      const nft = await deployAssetNFT();
      const [receiver, amount] = await nft.read.royaltyInfo([1n, 10000n]);
      assert.equal(receiver.toLowerCase(), ROYALTY_RECEIVER.toLowerCase());
      assert.equal(amount, 250n);
    });

    it("admin can update default royalty", async function () {
      const nft = await deployAssetNFT();
      await nft.write.setDefaultRoyalty([user2Address, 500n], {
        account: walletAdmin.account,
      });
      const [receiver, amount] = await nft.read.royaltyInfo([1n, 10000n]);
      assert.equal(receiver.toLowerCase(), user2Address.toLowerCase());
      assert.equal(amount, 500n);
    });

    it("admin can set per-token royalty override", async function () {
      const nft = await deployAssetNFT();
      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
        account: walletAdmin.account,
      });
      await nft.write.setTokenRoyalty([1n, user2Address, 1000n], {
        account: walletAdmin.account,
      });
      const [receiver, amount] = await nft.read.royaltyInfo([1n, 10000n]);
      assert.equal(receiver.toLowerCase(), user2Address.toLowerCase());
      assert.equal(amount, 1000n);
    });

    it("rejects royalty setter from non-admin", async function () {
      const nft = await deployAssetNFT();
      await assert.rejects(
        nft.write.setDefaultRoyalty([userAddress, 100n], {
          account: walletUser.account,
        }),
      );
    });
  });

  // =========================================================================
  // Pause
  // =========================================================================

  describe("Pause", async function () {
    it("pause blocks batchMint; unpause resumes", async function () {
      const nft = await deployAssetNFT();

      await nft.write.pause({ account: walletAdmin.account });
      assert.equal(await nft.read.paused(), true);

      await assert.rejects(
        nft.write.batchMint([[userAddress], [TOKEN_URI]], {
          account: walletAdmin.account,
        }),
      );

      await nft.write.unpause({ account: walletAdmin.account });
      assert.equal(await nft.read.paused(), false);

      await nft.write.batchMint([[userAddress], [TOKEN_URI]], {
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
    it("supports ERC721, ERC2981, ERC165, and IAccessControl", async function () {
      const nft = await deployAssetNFT();

      assert.equal(await nft.read.supportsInterface(["0x80ac58cd"]), true); // IERC721
      assert.equal(await nft.read.supportsInterface(["0x2a55205a"]), true); // IERC2981
      assert.equal(await nft.read.supportsInterface(["0x01ffc9a7"]), true); // IERC165
      assert.equal(await nft.read.supportsInterface(["0x7965db0b"]), true); // IAccessControl
    });
  });
});
