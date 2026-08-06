import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, toHex, keccak256, parseEther } from "viem";

const FORWARDER = "0x1234567890123456789012345678901234567890" as `0x${string}`;
const ZERO_BYTES32 = `0x${"00".repeat(32)}` as `0x${string}`;

function roleHash(role: string): `0x${string}` {
  return keccak256(toHex(role));
}

const MINTER_ROLE = roleHash("MINTER_ROLE");
const PACK_OPERATOR_ROLE = roleHash("PACK_OPERATOR_ROLE");
const PAUSER_ROLE = roleHash("PAUSER_ROLE");

const PRICE_PER_PACK = 10_000_000n; // 10 USDC (6 decimals)
const CARDS_PER_PACK = 3;
/** Packs opened per batch — the "charged for 4, opened 1" case this contract fixes. */
const QTY = 4;

describe("PackBatcher Integration", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();
  const [walletAdmin, walletOperator, walletUser, walletPayer] =
    await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const operatorAddress = walletOperator.account.address;
  const userAddress = walletUser.account.address;
  // Stands in for the card-settlement relayer: pays the USDC, receives no cards.
  const payerAddress = walletPayer.account.address;

  // ---------------------------------------------------------------------------
  // Deploy helpers
  // ---------------------------------------------------------------------------

  async function deployFullStack() {
    const pmImpl = await viem.deployContract("PermissionManager");
    const pmProxy = await viem.deployContract("ERC1967ProxyHelper", [
      pmImpl.address,
      encodeFunctionData({
        abi: pmImpl.abi,
        functionName: "initialize",
        args: [adminAddress],
      }),
    ]);
    const permissionManager = await viem.getContractAt(
      "PermissionManager",
      pmProxy.address,
    );

    for (const role of [PACK_OPERATOR_ROLE, MINTER_ROLE]) {
      await permissionManager.write.grantRole([role, operatorAddress], {
        account: walletAdmin.account,
      });
    }
    await permissionManager.write.grantRole([PAUSER_ROLE, adminAddress], {
      account: walletAdmin.account,
    });

    const usdc = await viem.deployContract("MockERC20");

    // AssetNFT
    const assetNFTImpl = await viem.deployContract("AssetNFT", [FORWARDER]);
    const assetNFTProxy = await viem.deployContract("ERC1967ProxyHelper", [
      assetNFTImpl.address,
      encodeFunctionData({
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
      }),
    ]);
    const assetNFT = await viem.getContractAt("AssetNFT", assetNFTProxy.address);

    // PackVRFRouter
    const coordinator = await viem.deployContract("MockVRFCoordinatorV2Plus");
    const routerImpl = await viem.deployContract("PackVRFRouter");
    const routerProxy = await viem.deployContract("ERC1967ProxyHelper", [
      routerImpl.address,
      encodeFunctionData({
        abi: routerImpl.abi,
        functionName: "initialize",
        args: [
          permissionManager.address,
          coordinator.address,
          1n,
          `0x${"ab".repeat(32)}` as `0x${string}`,
          500_000,
          3,
        ],
      }),
    ]);
    const vrfRouter = await viem.getContractAt(
      "PackVRFRouter",
      routerProxy.address,
    );

    // PackMachine implementation (linked libraries)
    const packPoolLib = await viem.deployContract("PackPoolLib");
    const packFulfillLib = await viem.deployContract("PackFulfillLib", [], {
      libraries: {
        "project/contracts/lib/PackPoolLib.sol:PackPoolLib": packPoolLib.address,
      },
    });
    const machineImpl = await viem.deployContract("PackMachine", [FORWARDER], {
      libraries: {
        "project/contracts/lib/PackPoolLib.sol:PackPoolLib": packPoolLib.address,
        "project/contracts/lib/PackFulfillLib.sol:PackFulfillLib":
          packFulfillLib.address,
      },
    });

    // PackMachineFactory — adminAddress doubles as the finance wallet.
    const factoryImpl = await viem.deployContract("PackMachineFactory", [
      FORWARDER,
    ]);
    const factoryProxy = await viem.deployContract("ERC1967ProxyHelper", [
      factoryImpl.address,
      encodeFunctionData({
        abi: factoryImpl.abi,
        functionName: "initialize",
        args: [
          permissionManager.address,
          assetNFT.address,
          usdc.address,
          adminAddress,
        ],
      }),
    ]);
    const factory = await viem.getContractAt(
      "PackMachineFactory",
      factoryProxy.address,
    );

    await factory.write.setImplementation([machineImpl.address], {
      account: walletAdmin.account,
    });
    await factory.write.setPackVRFRouter([vrfRouter.address], {
      account: walletAdmin.account,
    });

    // PackRegistry + PackTierRegistry — both wired before createPackMachine
    const registryImpl = await viem.deployContract("PackRegistry");
    const registryProxy = await viem.deployContract("ERC1967ProxyHelper", [
      registryImpl.address,
      encodeFunctionData({
        abi: registryImpl.abi,
        functionName: "initialize",
        args: [permissionManager.address],
      }),
    ]);
    const packRegistry = await viem.getContractAt(
      "PackRegistry",
      registryProxy.address,
    );
    await factory.write.setPackRegistry([packRegistry.address], {
      account: walletAdmin.account,
    });
    await packRegistry.write.setFactory([factory.address], {
      account: walletAdmin.account,
    });

    const tierRegistryImpl = await viem.deployContract("PackTierRegistry");
    const tierRegistryProxy = await viem.deployContract("ERC1967ProxyHelper", [
      tierRegistryImpl.address,
      encodeFunctionData({
        abi: tierRegistryImpl.abi,
        functionName: "initialize",
        args: [permissionManager.address],
      }),
    ]);
    const packTierRegistry = await viem.getContractAt(
      "PackTierRegistry",
      tierRegistryProxy.address,
    );
    await factory.write.setPackTierRegistry([packTierRegistry.address], {
      account: walletAdmin.account,
    });
    await packTierRegistry.write.setFactory([factory.address], {
      account: walletAdmin.account,
    });

    // PackMachine clone
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
    const packMachine = await viem.getContractAt(
      "PackMachine",
      events[0].args.packMachine!,
    );

    await vrfRouter.write.setAuthorizedPackMachine([packMachine.address, true], {
      account: walletOperator.account,
    });

    const mockLendingPool = await viem.deployContract("MockAssetLendingPool");
    await assetNFT.write.setLendingPool([mockLendingPool.address], {
      account: walletAdmin.account,
    });

    // Wide-open FMV bounds so unappraised deposits are accepted.
    const MAX_UINT128 = (1n << 128n) - 1n;
    await packRegistry.write.setPackTierFmvBounds(
      [
        packMachine.address,
        0n,
        [0n, 0n, 0n, 0n, 0n, 0n] as const,
        [
          MAX_UINT128,
          MAX_UINT128,
          MAX_UINT128,
          MAX_UINT128,
          MAX_UINT128,
          MAX_UINT128,
        ] as const,
      ],
      { account: walletOperator.account },
    );

    // PackBatcher — the system under test
    const batcherImpl = await viem.deployContract("PackBatcher");
    const batcherProxy = await viem.deployContract("ERC1967ProxyHelper", [
      batcherImpl.address,
      encodeFunctionData({
        abi: batcherImpl.abi,
        functionName: "initialize",
        args: [permissionManager.address, factory.address],
      }),
    ]);
    const batcher = await viem.getContractAt(
      "PackBatcher",
      batcherProxy.address,
    );

    return {
      permissionManager,
      usdc,
      assetNFT,
      coordinator,
      vrfRouter,
      factory,
      packMachine,
      packRegistry,
      batcher,
      packFulfillLib,
    };
  }

  /// @dev Deposits `count` NFTs, all into pack 0 / tier 0.
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
    await assetNFT.write.setApprovalForAll([packMachine.address, true], {
      account: walletOperator.account,
    });
    await packMachine.write.deposit(
      [
        tokenIds,
        Array(count).fill(1n) as bigint[],
        Array(count).fill(0n) as bigint[],
        Array(count).fill(0) as number[],
        operatorAddress,
      ],
      { account: walletOperator.account },
    );
    return tokenIds;
  }

  /// @dev Signs `count` OpenPack messages bound to CONSECUTIVE nonces starting at the
  ///      user's current on-chain nonce — exactly what the API's batch endpoint issues.
  ///      The code id goes on the first only, mirroring PackBatcher.openPacks.
  async function signOpenPackBatch(
    packMachineAddress: `0x${string}`,
    userAddr: `0x${string}`,
    startNonce: bigint,
    count: number,
    codeId: `0x${string}` = ZERO_BYTES32,
  ): Promise<`0x${string}`[]> {
    const chainId = await publicClient.getChainId();
    const signatures: `0x${string}`[] = [];
    for (let i = 0; i < count; i++) {
      signatures.push(
        await walletOperator.signTypedData({
          domain: {
            name: "PackMachine",
            version: "1",
            chainId,
            verifyingContract: packMachineAddress,
          },
          types: {
            OpenPack: [
              { name: "user", type: "address" },
              { name: "packId", type: "uint256" },
              { name: "nonce", type: "uint256" },
              { name: "codeId", type: "bytes32" },
            ],
          },
          primaryType: "OpenPack" as const,
          message: {
            user: userAddr,
            packId: 0n,
            nonce: startNonce + BigInt(i),
            codeId: i === 0 ? codeId : ZERO_BYTES32,
          },
        }),
      );
    }
    return signatures;
  }

  async function fulfill(
    coordinator: { address: `0x${string}` },
    vrfRouter: Awaited<ReturnType<typeof viem.getContractAt<"PackVRFRouter">>>,
    requestId: bigint,
  ) {
    await testClient.impersonateAccount({ address: coordinator.address });
    await testClient.setBalance({
      address: coordinator.address,
      value: parseEther("1"),
    });
    const randomWords = Array.from({ length: CARDS_PER_PACK }, (_, i) =>
      BigInt(keccak256(toHex(`${requestId}-${i}`))),
    );
    await vrfRouter.write.rawFulfillRandomWords([requestId, randomWords], {
      account: coordinator.address,
    });
  }

  // ---------------------------------------------------------------------------
  // Full batch flow
  // ---------------------------------------------------------------------------

  describe("Full multi-pack batch flow", async function () {
    it("charges once for N packs and opens all N in a single transaction", async function () {
      const { usdc, assetNFT, coordinator, vrfRouter, packMachine, batcher } =
        await deployFullStack();

      await depositNFTs(packMachine, assetNFT, QTY * CARDS_PER_PACK);

      const total = PRICE_PER_PACK * BigInt(QTY);
      await usdc.write.mint([payerAddress, total], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([batcher.address, total], {
        account: walletPayer.account,
      });

      const startNonce = (await packMachine.read.getUserInfo([userAddress]))
        .openNonce;
      const signatures = await signOpenPackBatch(
        packMachine.address,
        userAddress,
        startNonce,
        QTY,
      );

      const openBlock = await publicClient.getBlockNumber();
      await batcher.write.openPacks(
        [
          packMachine.address,
          userAddress,
          0n,
          signatures,
          ZERO_BYTES32,
          total,
        ],
        { account: walletPayer.account },
      );

      // The whole batch is escrowed on the machine — the charge matches the packs opened.
      assert.equal(await usdc.read.balanceOf([packMachine.address]), total);
      assert.equal(await usdc.read.balanceOf([payerAddress]), 0n);
      assert.equal(
        (await packMachine.read.getUserInfo([userAddress])).openNonce,
        startNonce + BigInt(QTY),
        "one nonce consumed per pack",
      );

      // Nothing is left behind on the batcher.
      assert.equal(await usdc.read.balanceOf([batcher.address]), 0n);
      assert.equal(
        await usdc.read.allowance([batcher.address, packMachine.address]),
        0n,
      );

      // One VRF request per pack.
      const requestEvents = await publicClient.getContractEvents({
        address: vrfRouter.address,
        abi: vrfRouter.abi,
        eventName: "RandomnessRequested",
        fromBlock: openBlock,
        strict: true,
      });
      assert.equal(requestEvents.length, QTY);

      for (const ev of requestEvents) {
        await fulfill(coordinator, vrfRouter, ev.args.requestId!);
      }

      // Every card from every pack lands on the recipient, not the payer.
      assert.equal(
        await assetNFT.read.balanceOf([userAddress]),
        BigInt(QTY * CARDS_PER_PACK),
      );
      assert.equal(await assetNFT.read.balanceOf([payerAddress]), 0n);

      // Payment settled through to the finance wallet; no escrow dust remains.
      assert.equal(await usdc.read.balanceOf([adminAddress]), total);
      assert.equal(await usdc.read.balanceOf([packMachine.address]), 0n);
    });

    it("refunds the payer when the machine consumes less than maxSpend", async function () {
      const { usdc, assetNFT, factory, packMachine, batcher } =
        await deployFullStack();

      await depositNFTs(packMachine, assetNFT, QTY * CARDS_PER_PACK);

      // The first-open discount applies to pack #0 only, so the batch costs less
      // than the sticker total and the difference must return to the payer.
      const discountBps = 1000n; // 10%
      await factory.write.setFirstOpenDiscount([true, Number(discountBps)], {
        account: walletAdmin.account,
      });

      const maxSpend = PRICE_PER_PACK * BigInt(QTY);
      const discount = (PRICE_PER_PACK * discountBps) / 10_000n;
      await usdc.write.mint([payerAddress, maxSpend], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([batcher.address, maxSpend], {
        account: walletPayer.account,
      });

      const startNonce = (await packMachine.read.getUserInfo([userAddress]))
        .openNonce;
      const signatures = await signOpenPackBatch(
        packMachine.address,
        userAddress,
        startNonce,
        QTY,
      );

      await batcher.write.openPacks(
        [
          packMachine.address,
          userAddress,
          0n,
          signatures,
          ZERO_BYTES32,
          maxSpend,
        ],
        { account: walletPayer.account },
      );

      assert.equal(
        await usdc.read.balanceOf([packMachine.address]),
        maxSpend - discount,
      );
      assert.equal(await usdc.read.balanceOf([payerAddress]), discount);
      assert.equal(await usdc.read.balanceOf([batcher.address]), 0n);
    });

    it("unwinds completely when the batch is under-funded", async function () {
      const { usdc, assetNFT, packMachine, batcher } = await deployFullStack();

      await depositNFTs(packMachine, assetNFT, QTY * CARDS_PER_PACK);

      // Enough for 2 of the 4 packs — the 3rd open must revert the whole batch
      // rather than leaving the buyer charged for packs they never received.
      const short = PRICE_PER_PACK * 2n;
      await usdc.write.mint([payerAddress, short], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([batcher.address, short], {
        account: walletPayer.account,
      });

      const signatures = await signOpenPackBatch(
        packMachine.address,
        userAddress,
        0n,
        QTY,
      );

      await assert.rejects(
        batcher.write.openPacks(
          [
            packMachine.address,
            userAddress,
            0n,
            signatures,
            ZERO_BYTES32,
            short,
          ],
          { account: walletPayer.account },
        ),
      );

      assert.equal(await usdc.read.balanceOf([packMachine.address]), 0n);
      assert.equal(await usdc.read.balanceOf([payerAddress]), short);
      assert.equal(
        (await packMachine.read.getUserInfo([userAddress])).openNonce,
        0n,
      );
    });

    it("rejects a machine that did not come from the configured factory", async function () {
      const { usdc, batcher } = await deployFullStack();

      await usdc.write.mint([payerAddress, PRICE_PER_PACK], {
        account: walletAdmin.account,
      });
      await usdc.write.approve([batcher.address, PRICE_PER_PACK], {
        account: walletPayer.account,
      });

      await assert.rejects(
        batcher.write.openPacks(
          [
            usdc.address, // not a PackMachine clone
            userAddress,
            0n,
            ["0x" as `0x${string}`],
            ZERO_BYTES32,
            PRICE_PER_PACK,
          ],
          { account: walletPayer.account },
        ),
      );
    });
  });
});
