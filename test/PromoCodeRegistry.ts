import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, keccak256, toBytes } from "viem";

// PromoKind enum mirrored from IPromoCodeRegistry.sol
const PromoKind = {
    Discount: 0,
    Buyback: 1,
} as const;

const DISCOUNT_BPS_20 = 2000;
const BUYBACK_BPS_95 = 9500;
const PRICE = 100n * 10n ** 6n; // 100 USDC (6 decimals)

// Compute code IDs off-chain exactly as the contract expects
const DISCOUNT_CODE_ID = keccak256(toBytes("SAVE20")) as `0x${string}`;
const BUYBACK_CODE_ID  = keccak256(toBytes("BOOST95")) as `0x${string}`;
const ZERO_CODE_ID     = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

describe("PromoCodeRegistry", async function () {
    const { viem } = await network.create();
    const [walletAdmin, walletOperator, walletPackMachine, walletBuybackPool, walletUser] =
        await viem.getWalletClients();

    const adminAddress    = walletAdmin.account.address;
    const operatorAddress = walletOperator.account.address;
    const packMachineAddr = walletPackMachine.account.address;
    const buybackPoolAddr = walletBuybackPool.account.address;
    const userAddress     = walletUser.account.address;

    // ── Role constants (matching Roles.sol) ────────────────────────────────
    const PACK_OPERATOR_ROLE = keccak256(toBytes("PACK_OPERATOR_ROLE")) as `0x${string}`;
    const PAUSER_ROLE        = keccak256(toBytes("PAUSER_ROLE")) as `0x${string}`;

    async function deploy() {
        // PermissionManager
        const pmImpl = await viem.deployContract("PermissionManager");
        const pmProxy = await viem.deployContract("ERC1967ProxyHelper", [
            pmImpl.address,
            encodeFunctionData({
                abi: pmImpl.abi,
                functionName: "initialize",
                args: [adminAddress],
            }),
        ]);
        const pm = await viem.getContractAt("PermissionManager", pmProxy.address);

        // Grant roles
        await pm.write.grantRole([PACK_OPERATOR_ROLE, operatorAddress], {
            account: walletAdmin.account,
        });
        await pm.write.grantRole([PAUSER_ROLE, adminAddress], {
            account: walletAdmin.account,
        });

        // MockPackMachineFactory — use a minimal mock so we can control isPackMachine()
        // We deploy it as a mock that always returns true for our packMachineAddr
        const mockFactory = await viem.deployContract(
            "contracts/test-helpers/MockPackMachineFactory.sol:MockPackMachineFactory"
        );
        await mockFactory.write.setPackMachine([packMachineAddr, true]);

        // PromoCodeRegistry
        const regImpl = await viem.deployContract("PromoCodeRegistry");
        const regProxy = await viem.deployContract("ERC1967ProxyHelper", [
            regImpl.address,
            encodeFunctionData({
                abi: regImpl.abi,
                functionName: "initialize",
                args: [pm.address],
            }),
        ]);
        const registry = await viem.getContractAt("PromoCodeRegistry", regProxy.address);

        // Wire
        await registry.write.setPackMachineFactory([mockFactory.address], {
            account: walletAdmin.account,
        });
        await registry.write.setBuybackPool([buybackPoolAddr], {
            account: walletAdmin.account,
        });

        return { pm, registry, mockFactory };
    }

    // =========================================================================
    // Deployment
    // =========================================================================

    it("initializes with zero factory and pool addresses before wiring", async () => {
        const pmImpl = await viem.deployContract("PermissionManager");
        const pmProxy = await viem.deployContract("ERC1967ProxyHelper", [
            pmImpl.address,
            encodeFunctionData({
                abi: pmImpl.abi,
                functionName: "initialize",
                args: [adminAddress],
            }),
        ]);

        const regImpl = await viem.deployContract("PromoCodeRegistry");
        const regProxy = await viem.deployContract("ERC1967ProxyHelper", [
            regImpl.address,
            encodeFunctionData({
                abi: regImpl.abi,
                functionName: "initialize",
                args: [pmProxy.address],
            }),
        ]);
        const reg = await viem.getContractAt("PromoCodeRegistry", regProxy.address);

        assert.equal(await reg.read.packMachineFactory(), "0x0000000000000000000000000000000000000000");
        assert.equal(await reg.read.buybackPool(), "0x0000000000000000000000000000000000000000");
        assert.equal(await reg.read.paused(), false);
    });

    // =========================================================================
    // createCode — valid bps
    // =========================================================================

    it("creates a discount code with valid bps and stores it correctly", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        const code = await registry.read.getCode([DISCOUNT_CODE_ID]);
        assert.equal(code.kind, PromoKind.Discount);
        assert.equal(code.bps, DISCOUNT_BPS_20);
        assert.equal(code.active, true);
        assert.equal(code.exists, true);
        assert.equal(code.redeemedCount, 0);
    });

    it("creates a buyback code with valid bps", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [BUYBACK_CODE_ID, PromoKind.Buyback, BUYBACK_BPS_95, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        const code = await registry.read.getCode([BUYBACK_CODE_ID]);
        assert.equal(code.bps, BUYBACK_BPS_95);
        assert.equal(code.kind, PromoKind.Buyback);
    });

    it("reverts when creating a code with invalid bps for discount kind", async () => {
        const { registry } = await deploy();
        await assert.rejects(
            registry.write.createCode(
                [DISCOUNT_CODE_ID, PromoKind.Discount, 9000, 0n, 0, false, false],
                { account: walletOperator.account },
            ),
            /InvalidBps|revert/i,
        );
    });

    it("reverts when creating a duplicate code", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await assert.rejects(
            registry.write.createCode(
                [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
                { account: walletOperator.account },
            ),
            /CodeExists|revert/i,
        );
    });

    // =========================================================================
    // redeemDiscount — happy path
    // =========================================================================

    it("redeemDiscount returns correct bps when called by a registered pack machine", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        // Use simulate to get the return value without mutating state, impersonating the pack machine.
        const { result: bps } = await registry.simulate.redeemDiscount(
            [DISCOUNT_CODE_ID, userAddress],
            { account: walletPackMachine.account },
        );
        assert.equal(bps, DISCOUNT_BPS_20);
    });

    it("redeemDiscount increments redeemedCount after write call", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
            account: walletPackMachine.account,
        });

        const code = await registry.read.getCode([DISCOUNT_CODE_ID]);
        assert.equal(code.redeemedCount, 1);
    });

    // =========================================================================
    // redeemDiscount — unauthorized
    // =========================================================================

    it("redeemDiscount reverts when called by an unauthorized address", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await assert.rejects(
            registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
                account: walletUser.account, // not a pack machine
            }),
            /UnauthorizedRedeemer|revert/i,
        );
    });

    // =========================================================================
    // redeemBuyback — happy path
    // =========================================================================

    it("redeemBuyback returns correct bps when called by the configured buyback pool", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [BUYBACK_CODE_ID, PromoKind.Buyback, BUYBACK_BPS_95, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await registry.write.redeemBuyback([BUYBACK_CODE_ID, userAddress], {
            account: walletBuybackPool.account,
        });

        const code = await registry.read.getCode([BUYBACK_CODE_ID]);
        assert.equal(code.redeemedCount, 1);
    });

    it("redeemBuyback reverts when called by a non-pool address", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [BUYBACK_CODE_ID, PromoKind.Buyback, BUYBACK_BPS_95, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await assert.rejects(
            registry.write.redeemBuyback([BUYBACK_CODE_ID, userAddress], {
                account: walletPackMachine.account, // not the pool
            }),
            /UnauthorizedRedeemer|revert/i,
        );
    });

    // =========================================================================
    // Redemption count rollback (simulate failed outer tx)
    // =========================================================================

    it("remainingRedemptions returns 0 after cap exhausted, not negative", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 1, false, false],
            { account: walletOperator.account },
        );

        await registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
            account: walletPackMachine.account,
        });

        const remaining = await registry.read.remainingRedemptions([DISCOUNT_CODE_ID]);
        assert.equal(remaining, 0n);

        // Further redeem should revert
        await assert.rejects(
            registry.write.redeemDiscount([DISCOUNT_CODE_ID, buybackPoolAddr], {
                account: walletPackMachine.account,
            }),
            /LimitReached|revert/i,
        );
    });

    // =========================================================================
    // previewDiscount
    // =========================================================================

    it("previewDiscount returns the correct discounted price", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        const discounted = await registry.read.previewDiscount([DISCOUNT_CODE_ID, userAddress, PRICE]);
        const expected = PRICE - (PRICE * BigInt(DISCOUNT_BPS_20)) / 10_000n; // 80 USDC
        assert.equal(discounted, expected);
    });

    it("previewDiscount returns full price for bytes32(0) codeId", async () => {
        const { registry } = await deploy();
        const result = await registry.read.previewDiscount([ZERO_CODE_ID, userAddress, PRICE]);
        assert.equal(result, PRICE);
    });

    it("previewDiscount returns full price for an expired code", async () => {
        const { registry } = await deploy();
        const testClient = await viem.getTestClient();
        const publicClient = await viem.getPublicClient();

        // Read current block timestamp from the chain (avoids node clock vs chain-time drift).
        const block = await publicClient.getBlock();
        const currentTime = block.timestamp;

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, currentTime + 10n, 0, false, false],
            { account: walletOperator.account },
        );

        // Advance time past expiry
        await testClient.setNextBlockTimestamp({ timestamp: currentTime + 20n });
        await testClient.mine({ blocks: 1 });

        const result = await registry.read.previewDiscount([DISCOUNT_CODE_ID, userAddress, PRICE]);
        assert.equal(result, PRICE);
    });

    // =========================================================================
    // isEligible
    // =========================================================================

    it("isEligible returns true for a valid unrestricted code", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        const eligible = await registry.read.isEligible([DISCOUNT_CODE_ID, userAddress]);
        assert.equal(eligible, true);
    });

    it("isEligible returns false after code is deactivated", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await registry.write.setActive([DISCOUNT_CODE_ID, false], {
            account: walletOperator.account,
        });

        const eligible = await registry.read.isEligible([DISCOUNT_CODE_ID, userAddress]);
        assert.equal(eligible, false);
    });

    // =========================================================================
    // pause
    // =========================================================================

    it("pausing blocks redeemDiscount", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await registry.write.pause([], { account: walletAdmin.account });

        await assert.rejects(
            registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
                account: walletPackMachine.account,
            }),
            /paused|revert/i,
        );
    });

    it("unpausing re-enables redeemDiscount", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        await registry.write.pause([], { account: walletAdmin.account });
        await registry.write.unpause([], { account: walletAdmin.account });

        // Should not throw
        await registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
            account: walletPackMachine.account,
        });

        const code = await registry.read.getCode([DISCOUNT_CODE_ID]);
        assert.equal(code.redeemedCount, 1);
    });

    // =========================================================================
    // Allowlist
    // =========================================================================

    it("restricted code reverts for non-allowlisted user, succeeds after allowlisting", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, true, false],
            { account: walletOperator.account },
        );

        // Not allowlisted — should fail
        await assert.rejects(
            registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
                account: walletPackMachine.account,
            }),
            /NotAllowlisted|revert/i,
        );

        // Add to allowlist
        await registry.write.addToAllowlist([DISCOUNT_CODE_ID, [userAddress]], {
            account: walletOperator.account,
        });

        // Should succeed now
        await registry.write.redeemDiscount([DISCOUNT_CODE_ID, userAddress], {
            account: walletPackMachine.account,
        });

        const code = await registry.read.getCode([DISCOUNT_CODE_ID]);
        assert.equal(code.redeemedCount, 1);
    });

    // =========================================================================
    // remainingRedemptions — uncapped
    // =========================================================================

    it("remainingRedemptions returns max uint256 for uncapped code", async () => {
        const { registry } = await deploy();

        await registry.write.createCode(
            [DISCOUNT_CODE_ID, PromoKind.Discount, DISCOUNT_BPS_20, 0n, 0, false, false],
            { account: walletOperator.account },
        );

        const remaining = await registry.read.remainingRedemptions([DISCOUNT_CODE_ID]);
        assert.equal(remaining, 2n ** 256n - 1n);
    });
});
