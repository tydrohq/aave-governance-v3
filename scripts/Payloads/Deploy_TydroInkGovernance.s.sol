// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {Executor} from "../../src/contracts/payloads/Executor.sol";
import {
    PermissionedPayloadsController,
    PayloadsControllerUtils,
    IPayloadsControllerCore
} from "../../src/contracts/payloads/PermissionedPayloadsController.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    ITransparentProxyFactory
} from "solidity-utils/contracts/transparent-proxy/interfaces/ITransparentProxyFactory.sol";

/**
 * @notice Bitwise pool on Ink mainnet: Executor + PermissionedPayloadsController in one run.
 * @dev Standalone: same script as our Ink Sepolia pools (GovBaseScript does not support Ink Sepolia).
 * Fixes the upstream script, which calls initialize without the owner argument.
 * 4 txs: Executor, controller impl, controller proxy (initialized), Executor.transferOwnership(controller).
 */
contract TydroInkBitwise is Script {
    // BGD TransparentProxyFactory on Ink mainnet (aave-address-book GovernanceV3Ink)
    address public constant PROXY_FACTORY = 0xEB0682d148e874553008730f0686ea89db7DA412;
    // TODO: Super Admin = payloadsManager, proposes payloads (Bitwise Safe 4/8, Tydro as proposer)
    address public constant SUPER_ADMIN = address(0);
    // TODO: Guardian Safe = controller guardian, cancels queued payloads (1/2, nested Bitwise + Tydro Safes)
    address public constant GUARDIAN = address(0);
    uint40 public constant DELAY = 24 hours;

    function run() external {
        require(block.chainid == 57073, "not Ink");
        require(SUPER_ADMIN != address(0) && GUARDIAN != address(0), "placeholder role");

        vm.startBroadcast();

        address executor = address(new Executor());
        address controllerImpl = address(new PermissionedPayloadsController());

        IPayloadsControllerCore.UpdateExecutorInput[] memory executors =
            new IPayloadsControllerCore.UpdateExecutorInput[](1);
        executors[0] = IPayloadsControllerCore.UpdateExecutorInput({
            accessLevel: PayloadsControllerUtils.AccessControl.Level_1,
            executorConfig: IPayloadsControllerCore.ExecutorConfig({executor: executor, delay: DELAY})
        });

        address controller = ITransparentProxyFactory(PROXY_FACTORY)
            .create(
                controllerImpl,
                executor, // owner of the proxy admin
                abi.encodeWithSelector(
                    PermissionedPayloadsController.initialize.selector,
                    executor, // owner
                    GUARDIAN,
                    SUPER_ADMIN, // payloadsManager
                    executors
                )
            );

        Ownable(executor).transferOwnership(controller);

        vm.stopBroadcast();

        // post-conditions
        PermissionedPayloadsController c = PermissionedPayloadsController(payable(controller));
        require(c.owner() == executor, "controller owner");
        require(c.guardian() == GUARDIAN, "controller guardian");
        require(c.payloadsManager() == SUPER_ADMIN, "payloadsManager");
        IPayloadsControllerCore.ExecutorConfig memory cfg =
            c.getExecutorSettingsByAccessControl(PayloadsControllerUtils.AccessControl.Level_1);
        require(cfg.executor == executor && cfg.delay == DELAY, "executor config");
        require(Ownable(executor).owner() == controller, "executor owner");
        address proxyAdmin = ITransparentProxyFactory(PROXY_FACTORY).getProxyAdmin(controller);
        require(Ownable(proxyAdmin).owner() == executor, "proxy admin owner");

        console.log("Executor:", executor);
        console.log("PermissionedPayloadsController impl:", controllerImpl);
        console.log("PermissionedPayloadsController proxy:", controller);
        console.log("Controller ProxyAdmin:", proxyAdmin);
    }
}
