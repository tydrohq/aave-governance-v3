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
 * @dev Standalone: the upstream script calls initialize without the owner argument.
 * 4 txs: Executor, controller impl, controller proxy (initialized), Executor.transferOwnership(controller).
 */
contract TydroInkBitwise is Script {
    // TransparentProxyFactory already deployed on Ink mainnet (aave-address-book GovernanceV3Ink)
    address public constant PROXY_FACTORY = 0xEB0682d148e874553008730f0686ea89db7DA412;
    // TODO: Super Admin Safe (Bitwise 4/8, Tydro as proposer). Set as both:
    // - payloadsManager: creates payloads, and can always cancel them
    // - guardian of the governance (controller guardian, not the market's EMERGENCY_ADMIN): can only
    //   cancel queued payloads and hand this role to another address (updateGuardian)
    address public constant SUPER_ADMIN = address(0);
    uint40 public constant DELAY = 24 hours;

    function run() external {
        require(block.chainid == 57073, "not Ink");
        require(SUPER_ADMIN != address(0), "placeholder role");

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
                    SUPER_ADMIN, // guardian of the governance: cancels queued payloads
                    SUPER_ADMIN, // payloadsManager: creates payloads (and can cancel them)
                    executors // Level_1: Executor + 24h delay
                )
            );

        // Circular ownership, by design: the controller owns the Executor (only the controller can make it
        // execute payloads) and the Executor owns the controller (controller changes go through a payload).
        // Same setup as Tydro on Ink mainnet (Executor 0x1dF4…053D <-> controller 0x1dE9…3b7A).
        Ownable(executor).transferOwnership(controller);

        vm.stopBroadcast();

        // post-conditions
        PermissionedPayloadsController c = PermissionedPayloadsController(payable(controller));
        require(c.owner() == executor, "controller owner");
        require(c.guardian() == SUPER_ADMIN, "controller guardian");
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
