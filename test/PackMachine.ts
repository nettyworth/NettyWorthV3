import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, toHex, keccak256, parseEther } from "viem";

const FORWARDER = "0x1234567890123456789012345678901234567890" as `0x${string}`;
const PERMIT2_ADDRESS =
  "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`;

function roleHash(role: string): `0x${string}` {
  return keccak256(toHex(role));
}

const MINTER_ROLE = roleHash("MINTER_ROLE");
const PACK_OPERATOR_ROLE = roleHash("PACK_OPERATOR_ROLE");
const PAUSER_ROLE = roleHash("PAUSER_ROLE");

const PRICE_PER_PACK = 10_000_000n; // 10 USDC (6 decimals)
const CARDS_PER_PACK = 3;

describe("PackMachine Integration", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();
  const [walletAdmin, walletOperator, walletUser, walletUser2, walletPauser] =
    await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const operatorAddress = walletOperator.account.address;
  const userAddress = walletUser.account.address;
  const user2Address = walletUser2.account.address;
  const pauserAddress = walletPauser.account.address;

  // ---------------------------------------------------------------------------
  // Deploy helpers
  // ---------------------------------------------------------------------------

  async function deployFullStack() {
    // PermissionManager
    const pmImpl = await viem.deployContract("PermissionManager");
    const pmInitData = encodeFunctionData({
      abi: pmImpl.abi,
      functionName: "initialize",
      args: [adminAddress],
    });
    const pmProxy = await viem.deployContract("ERC1967ProxyHelper", [
      pmImpl.address,
      pmInitData,
    ]);
    const permissionManager = await viem.getContractAt(
      "PermissionManager",
      pmProxy.address,
    );

    // Grant roles
    await permissionManager.write.grantRole(
      [PACK_OPERATOR_ROLE, operatorAddress],
      {
        account: walletAdmin.account,
      },
    );
    await permissionManager.write.grantRole([PAUSER_ROLE, pauserAddress], {
      account: walletAdmin.account,
    });
    await permissionManager.write.grantRole([MINTER_ROLE, operatorAddress], {
      account: walletAdmin.account,
    });

    // Mock tokens
    const usdc = await viem.deployContract("MockERC20");

    // AssetNFT (UUPS proxy)
    const assetNFTImpl = await viem.deployContract("AssetNFT", [FORWARDER]);
    const assetNFTInitData = encodeFunctionData({
      abi: assetNFTImpl.abi,
      functionName: "initialize",
      args: [
        permissionManager.address,
        "NettyWorth Assets",
        "NWA",
        "ipfs://contract",
        adminAddress,
        250n,
      ],
    });
    const assetNFTProxy = await viem.deployContract("ERC1967ProxyHelper", [
      assetNFTImpl.address,
      assetNFTInitData,
    ]);
    const assetNFT = await viem.getContractAt(
      "AssetNFT",
      assetNFTProxy.address,
    );

    // Mock VRF coordinator
    const coordinator = await viem.deployContract("MockVRFCoordinatorV2Plus");

    // MockPermit2: deploy then setCode at canonical address
    const permit2Impl = await viem.deployContract("MockPermit2");
    const permit2Bytecode = await publicClient.getCode({
      address: permit2Impl.address,
    });
    await testClient.setCode({
      address: PERMIT2_ADDRESS,
      bytecode: permit2Bytecode!,
    });

    // PackVRFRouter
    const routerImpl = await viem.deployContract("PackVRFRouter");
    const routerInitData = encodeFunctionData({
      abi: routerImpl.abi,
      functionName: "initialize",
      args: [
        permissionManager.address,
        coordinator.address,
        1n, // subscriptionId
        `0x${"ab".repeat(32)}` as `0x${string}`, // keyHash
        500_000, // callbackGasLimit
        3, // requestConfirmations
      ],
    });
    const routerProxy = await viem.deployContract("ERC1967ProxyHelper", [
      routerImpl.address,
      routerInitData,
    ]);
    const vrfRouter = await viem.getContractAt(
      "PackVRFRouter",
      routerProxy.address,
    );

    // PackMachine implementation
    const machineImpl = await viem.deployContract("PackMachine", [FORWARDER]);

    // PackMachineFactory
    const factoryImpl = await viem.deployContract("PackMachineFactory", [
      FORWARDER,
    ]);
    const factoryInitData = encodeFunctionData({
      abi: factoryImpl.abi,
      functionName: "initialize",
      args: [
        permissionManager.address,
        assetNFT.address,
        usdc.address,
        adminAddress,
      ],
    });
    const factoryProxy = await viem.deployContract("ERC1967ProxyHelper", [
      factoryImpl.address,
      factoryInitData,
    ]);
    const factory = await viem.getContractAt(
      "PackMachineFactory",
      factoryProxy.address,
    );

    // Wire up factory
    await factory.write.setImplementation([machineImpl.address], {
      account: walletAdmin.account,
    });
    await factory.write.setPackVRFRouter([vrfRouter.address], {
      account: walletAdmin.account,
    });

    // Create a PackMachine clone
    const startBlock = await publicClient.getBlockNumber();
    await factory.write.createPackMachine(
      [PRICE_PER_PACK, CARDS_PER_PACK, Math.floor(Date.now() / 1000)],
      { account: walletOperator.account },
    );

    const events = await publicClient.getContractEvents({
      address: factory.address,
      abi: factory.abi,
      eventName: "PackMachineCreated",
      fromBlock: startBlock,
      strict: true,
    });
    assert.equal(events.length, 1);
    const packMachineAddress = events[0].args.packMachine!;
    const packMachine = await viem.getContractAt(
      "PackMachine",
      packMachineAddress,
    );

    // Authorize on VRF router
    await vrfRouter.write.setAuthorizedPackMachine([packMachineAddress, true], {
      account: walletOperator.account,
    });

    return {
      permissionManager,
      usdc,
      assetNFT,
      coordinator,
      vrfRouter,
      factory,
      packMachine,
    };
  }

  /// @dev Deposits `count` NFTs all into tier 0 (Base).
  async function depositNFTs(
    packMachine: Awaited<ReturnType<typeof viem.getContractAt<"PackMachine">>>,
    assetNFT: Awaited<ReturnType<typeof viem.getContractAt<"AssetNFT">>>,
    count: number,
  ) {
    const currentSupply = await assetNFT.read.totalSupply();
    const startId = Number(currentSupply) + 1;
    const recipients = Array(count).fill(operatorAddress) as `0x${string}`[];
    const uris = Array.from(
      { length: count },
      (_, i) => `https://example.com/token/${startId + i}`,
    );
    await assetNFT.write.batchMint([recipients, uris], {
      account: walletOperator.account,
    });
    const tokenIds = Array.from({ length: count }, (_, i) =>
      BigInt(startId + i),
    );
    const tiers = Array(count).fill(0) as number[]; // all Base
    await assetNFT.write.setApprovalForAll([packMachine.address, true], {
      account: walletOperator.account,
    });
    await packMachine.write.deposit([tokenIds, tiers, operatorAddress], {
      account: walletOperator.account,
    });
    return tokenIds;
  }

  /// @dev Returns the sum of all tier pool sizes.
  async function getTotalPoolSize(
    packMachine: Awaited<ReturnType<typeof viem.getContractAt<"PackMachine">>>,
  ): Promise<bigint> {
    let total = 0n;
    for (let t = 0; t < 5; t++) {
      total += await packMachine.read.getTierPoolSize([t]);
    }
    return total;
  }

  function buildOpenPackTypedData(
    packMachineAddress: `0x${string}`,
    chainId: number,
    userAddr: `0x${string}`,
    nonce: bigint,
  ) {
    return {
      domain: {
        name: "PackMachine",
        version: "1",
        chainId,
        verifyingContract: packMachineAddress,
      },
      types: {
        OpenPack: [
          { name: "user", type: "address" },
          { name: "nonce", type: "uint256" },
        ],
      },
      primaryType: "OpenPack" as const,
      message: { user: userAddr, nonce },
    };
  }

  // ---------------------------------------------------------------------------
  // Full openPackWithPermit2 flow
  // ---------------------------------------------------------------------------

  describe("Full openPackWithPermit2 flow", async function () {
    it("should deposit NFTs, open pack via Permit2, deliver cards via VRF callback", async function () {
      const { usdc, assetNFT, coordinator, vrfRouter, packMachine } =
        await deployFullStack();

      // Deposit NFTs
      await depositNFTs(packMachine, assetNFT, CARDS_PER_PACK);
      assert.equal(
        await packMachine.read.effectivePrizePoolSize(),
        BigInt(CARDS_PER_PACK),
      );

      // Mint USDC to user and approve Permit2
      await usdc.write.mint([userAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([PERMIT2_ADDRESS, PRICE_PER_PACK], {
        account: walletUser.account,
      });

      // Operator signs EIP-712 OpenPack
      const chainId = await publicClient.getChainId();
      const typedData = buildOpenPackTypedData(
        packMachine.address,
        chainId,
        userAddress,
        0n,
      );
      const playSig = await walletOperator.signTypedData(typedData);
      // await packMachine.write.unpause({ account: walletAdmin.account });
      // Call openPackWithPermit2 (MockPermit2 skips signature verification)
      const openBlock = await publicClient.getBlockNumber();
      await packMachine.write.openPackWithPermit2(
        [
          userAddress,
          0n, // permit2Nonce
          BigInt(Math.floor(Date.now() / 1000) + 3600), // deadline
          "0x", // permit2Signature (not verified by mock)
          playSig,
        ],
        { account: walletUser.account },
      );

      // effectivePrizePoolSize decremented at request time
      assert.equal(await packMachine.read.effectivePrizePoolSize(), 0n);

      // USDC should have moved to finance wallet (admin in this test)
      assert.equal(await usdc.read.balanceOf([adminAddress]), PRICE_PER_PACK);
      assert.equal(await usdc.read.balanceOf([userAddress]), 0n);

      // Simulate VRF fulfillment: coordinator calls rawFulfillRandomWords on router
      const requestId = 1n;
      const randomWords = [
        BigInt("0x" + "a1".repeat(32)),
        BigInt("0x" + "b2".repeat(32)),
        BigInt("0x" + "c3".repeat(32)),
      ];

      await testClient.impersonateAccount({ address: coordinator.address });
      await testClient.setBalance({
        address: coordinator.address,
        value: parseEther("1"),
      });

      await vrfRouter.write.rawFulfillRandomWords([requestId, randomWords], {
        account: coordinator.address,
      });

      // User should now own all CARDS_PER_PACK NFTs
      const userBalance = await assetNFT.read.balanceOf([userAddress]);
      assert.equal(userBalance, BigInt(CARDS_PER_PACK));

      // Pool should be empty
      assert.equal(await getTotalPoolSize(packMachine), 0n);

      // CardWon events emitted
      const cardWonEvents = await publicClient.getContractEvents({
        address: packMachine.address,
        abi: packMachine.abi,
        eventName: "CardWon",
        fromBlock: openBlock,
        strict: true,
      });
      assert.equal(cardWonEvents.length, CARDS_PER_PACK);
      for (const ev of cardWonEvents) {
        assert.equal(ev.args.user?.toLowerCase(), userAddress.toLowerCase());
        assert.equal(ev.args.requestId, requestId);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // openPack direct flow
  // ---------------------------------------------------------------------------

  describe("openPack direct USDC flow", async function () {
    it("should transfer USDC directly and request VRF", async function () {
      const { usdc, assetNFT, coordinator, vrfRouter, packMachine } =
        await deployFullStack();

      await depositNFTs(packMachine, assetNFT, CARDS_PER_PACK);

      await usdc.write.mint([userAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([packMachine.address, PRICE_PER_PACK], {
        account: walletUser.account,
      });

      const chainId = await publicClient.getChainId();
      const typedData = buildOpenPackTypedData(
        packMachine.address,
        chainId,
        userAddress,
        0n,
      );
      const playSig = await walletOperator.signTypedData(typedData);

      await packMachine.write.openPack([userAddress, playSig], {
        account: walletUser.account,
      });

      assert.equal(await usdc.read.balanceOf([adminAddress]), PRICE_PER_PACK);
      assert.equal(await packMachine.read.effectivePrizePoolSize(), 0n);

      // Fulfill and verify cards received
      await testClient.impersonateAccount({ address: coordinator.address });
      await testClient.setBalance({
        address: coordinator.address,
        value: parseEther("1"),
      });
      await vrfRouter.write.rawFulfillRandomWords(
        [1n, [12345n, 67890n, 11111n]],
        { account: coordinator.address },
      );

      assert.equal(
        await assetNFT.read.balanceOf([userAddress]),
        BigInt(CARDS_PER_PACK),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Tier weights
  // ---------------------------------------------------------------------------

  describe("Tier weights", async function () {
    it("should initialize with default weights summing to 10000", async function () {
      const { packMachine } = await deployFullStack();
      const weights = await packMachine.read.getTierWeights();
      const sum = (weights as readonly number[]).reduce((a, b) => a + b, 0);
      assert.equal(sum, 10000);
      assert.equal(weights[0], 7500); // Base 75%
      assert.equal(weights[1], 1950); // Common 19.5%
      assert.equal(weights[2], 400); // Uncommon 4%
      assert.equal(weights[3], 100); // Rare 1%
      assert.equal(weights[4], 50); // Ultra 0.5%
    });

    it("operator can update tier weights", async function () {
      const { packMachine } = await deployFullStack();
      const newWeights = [5000, 2000, 1500, 1000, 500] as const;
      await packMachine.write.setTierWeights([newWeights], {
        account: walletOperator.account,
      });
      const stored = await packMachine.read.getTierWeights();
      assert.equal(stored[0], 5000);
      assert.equal(stored[4], 500);
    });

    it("rejects weights that do not sum to 10000", async function () {
      const { packMachine } = await deployFullStack();
      const badWeights = [5000, 2000, 1500, 1000, 100] as const; // sums to 9600
      await assert.rejects(
        packMachine.write.setTierWeights([badWeights], {
          account: walletOperator.account,
        }),
      );
    });

    it("non-operator cannot update tier weights", async function () {
      const { packMachine } = await deployFullStack();
      const weights = [5000, 2000, 1500, 1000, 500] as const;
      await assert.rejects(
        packMachine.write.setTierWeights([weights], {
          account: walletUser.account,
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Deposit tier routing
  // ---------------------------------------------------------------------------

  describe("Deposit tier routing", async function () {
    it("routes tokens to correct tier pools", async function () {
      const { assetNFT, packMachine } = await deployFullStack();

      const count = 5;
      const currentSupply = await assetNFT.read.totalSupply();
      const startId = Number(currentSupply) + 1;
      const recipients = Array(count).fill(operatorAddress) as `0x${string}`[];
      const uris = Array.from({ length: count }, (_, i) => `uri://${i}`);
      await assetNFT.write.batchMint([recipients, uris], {
        account: walletOperator.account,
      });
      const tokenIds = Array.from({ length: count }, (_, i) =>
        BigInt(startId + i),
      );
      // 2 Base, 2 Common, 1 Rare
      const tiers = [0, 0, 1, 1, 3] as const;
      await assetNFT.write.setApprovalForAll([packMachine.address, true], {
        account: walletOperator.account,
      });
      await packMachine.write.deposit([tokenIds, tiers, operatorAddress], {
        account: walletOperator.account,
      });

      assert.equal(await packMachine.read.getTierPoolSize([0]), 2n); // Base
      assert.equal(await packMachine.read.getTierPoolSize([1]), 2n); // Common
      assert.equal(await packMachine.read.getTierPoolSize([2]), 0n); // Uncommon
      assert.equal(await packMachine.read.getTierPoolSize([3]), 1n); // Rare
      assert.equal(await packMachine.read.getTierPoolSize([4]), 0n); // Ultra
      assert.equal(await packMachine.read.effectivePrizePoolSize(), 5n);
    });

    it("rejects mismatched array lengths", async function () {
      const { packMachine } = await deployFullStack();
      await assert.rejects(
        packMachine.write.deposit([[1n, 2n], [0], operatorAddress], {
          account: walletOperator.account,
        }),
      );
    });

    it("rejects invalid tier index", async function () {
      const { assetNFT, packMachine } = await deployFullStack();
      const currentSupply = await assetNFT.read.totalSupply();
      const startId = Number(currentSupply) + 1;
      await assetNFT.write.batchMint([[operatorAddress], ["uri://x"]], {
        account: walletOperator.account,
      });
      await assetNFT.write.setApprovalForAll([packMachine.address, true], {
        account: walletOperator.account,
      });
      await assert.rejects(
        packMachine.write.deposit([[BigInt(startId)], [5], operatorAddress], {
          account: walletOperator.account,
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Access control
  // ---------------------------------------------------------------------------

  describe("Access control", async function () {
    it("non-operator cannot deposit", async function () {
      const { assetNFT, packMachine } = await deployFullStack();
      await assetNFT.write.batchMint([[userAddress], ["uri://1"]], {
        account: walletAdmin.account,
      });
      await assert.rejects(
        packMachine.write.deposit([[1n], [0], userAddress], {
          account: walletUser.account,
        }),
      );
    });

    it("non-pauser cannot pause", async function () {
      const { packMachine } = await deployFullStack();
      await assert.rejects(
        packMachine.write.pause({ account: walletUser.account }),
      );
    });

    it("non-operator cannot create pack machine", async function () {
      const { factory } = await deployFullStack();
      await assert.rejects(
        factory.write.createPackMachine(
          [PRICE_PER_PACK, CARDS_PER_PACK, Math.floor(Date.now() / 1000)],
          { account: walletUser.account },
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases
  // ---------------------------------------------------------------------------

  describe("Edge cases", async function () {
    it("cannot open pack before startTime", async function () {
      const {
        usdc,
        assetNFT,
        factory,
        vrfRouter,
        packMachine: _,
      } = await deployFullStack();

      // Create a separate machine with future startTime
      const futureStart = Math.floor(Date.now() / 1000) + 9999;
      const startBlock = await publicClient.getBlockNumber();
      await factory.write.createPackMachine(
        [PRICE_PER_PACK, CARDS_PER_PACK, futureStart],
        {
          account: walletOperator.account,
        },
      );
      const events = await publicClient.getContractEvents({
        address: factory.address,
        abi: factory.abi,
        eventName: "PackMachineCreated",
        fromBlock: startBlock,
        strict: true,
      });
      const futureMachineAddr = events[events.length - 1].args.packMachine!;
      const futureMachine = await viem.getContractAt(
        "PackMachine",
        futureMachineAddr,
      );
      await vrfRouter.write.setAuthorizedPackMachine(
        [futureMachineAddr, true],
        {
          account: walletOperator.account,
        },
      );

      const mintRecipients = Array(CARDS_PER_PACK).fill(
        operatorAddress,
      ) as `0x${string}`[];
      const mintUris = Array.from(
        { length: CARDS_PER_PACK },
        (_, i) => `uri://future-${i}`,
      );
      await assetNFT.write.batchMint([mintRecipients, mintUris], {
        account: walletOperator.account,
      });
      const currentSupply = await assetNFT.read.totalSupply();
      const ids = Array.from({ length: CARDS_PER_PACK }, (_, i) =>
        BigInt(Number(currentSupply) - CARDS_PER_PACK + 1 + i),
      );
      const tiers = Array(CARDS_PER_PACK).fill(0) as number[];
      await assetNFT.write.setApprovalForAll([futureMachineAddr, true], {
        account: walletOperator.account,
      });
      await futureMachine.write.deposit([ids, tiers, operatorAddress], {
        account: walletOperator.account,
      });

      await usdc.write.mint([userAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([futureMachineAddr, PRICE_PER_PACK], {
        account: walletUser.account,
      });

      const chainId = await publicClient.getChainId();
      const typedData = buildOpenPackTypedData(
        futureMachineAddr,
        chainId,
        userAddress,
        0n,
      );
      const playSig = await walletOperator.signTypedData(typedData);

      await assert.rejects(
        futureMachine.write.openPack([userAddress, playSig], {
          account: walletUser.account,
        }),
      );
    });

    it("cannot open pack after stop", async function () {
      const { usdc, assetNFT, packMachine } = await deployFullStack();

      await depositNFTs(packMachine, assetNFT, CARDS_PER_PACK);
      await packMachine.write.stop({ account: walletOperator.account });

      await usdc.write.mint([userAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([packMachine.address, PRICE_PER_PACK], {
        account: walletUser.account,
      });

      const chainId = await publicClient.getChainId();
      const typedData = buildOpenPackTypedData(
        packMachine.address,
        chainId,
        userAddress,
        0n,
      );
      const playSig = await walletOperator.signTypedData(typedData);

      await assert.rejects(
        packMachine.write.openPack([userAddress, playSig], {
          account: walletUser.account,
        }),
      );
    });

    it("multiple packs can be opened independently by different users", async function () {
      const { usdc, assetNFT, coordinator, vrfRouter, packMachine } =
        await deployFullStack();

      // Deposit enough cards for 2 packs
      await depositNFTs(packMachine, assetNFT, CARDS_PER_PACK * 10);

      await usdc.write.mint([userAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.mint([user2Address, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([packMachine.address, PRICE_PER_PACK], {
        account: walletUser.account,
      });
      await usdc.write.approve([packMachine.address, PRICE_PER_PACK], {
        account: walletUser2.account,
      });

      const chainId = await publicClient.getChainId();

      const sig1 = await walletOperator.signTypedData(
        buildOpenPackTypedData(packMachine.address, chainId, userAddress, 0n),
      );
      const sig2 = await walletOperator.signTypedData(
        buildOpenPackTypedData(packMachine.address, chainId, user2Address, 0n),
      );

      await packMachine.write.openPack([userAddress, sig1], {
        account: walletUser.account,
      });
      await packMachine.write.openPack([user2Address, sig2], {
        account: walletUser2.account,
      });

      await testClient.impersonateAccount({ address: coordinator.address });
      await testClient.setBalance({
        address: coordinator.address,
        value: parseEther("1"),
      });

      await vrfRouter.write.rawFulfillRandomWords([1n, [11n, 22n, 33n]], {
        account: coordinator.address,
      });
      await vrfRouter.write.rawFulfillRandomWords([2n, [44n, 55n, 66n]], {
        account: coordinator.address,
      });

      assert.equal(
        await assetNFT.read.balanceOf([userAddress]),
        BigInt(CARDS_PER_PACK),
      );
      assert.equal(
        await assetNFT.read.balanceOf([user2Address]),
        BigInt(CARDS_PER_PACK),
      );
    });
  });
});
