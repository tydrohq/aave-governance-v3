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
abstract contract TydroInkGovernanceBase is Script {
    // BGD TransparentProxyFactory on Ink mainnet (aave-address-book GovernanceV3Ink)
    address public constant PROXY_FACTORY_INK = 0xEB0682d148e874553008730f0686ea89db7DA412;

    function _deploy(address proxyFactory, address payloadsManager, address guardian, uint40 delay) internal {
        require(payloadsManager != address(0) && guardian != address(0), "placeholder role");

        vm.startBroadcast();

        address executor = address(new Executor());
        address controllerImpl = address(new PermissionedPayloadsController());

        IPayloadsControllerCore.UpdateExecutorInput[] memory executors =
            new IPayloadsControllerCore.UpdateExecutorInput[](1);
        executors[0] = IPayloadsControllerCore.UpdateExecutorInput({
            accessLevel: PayloadsControllerUtils.AccessControl.Level_1,
            executorConfig: IPayloadsControllerCore.ExecutorConfig({executor: executor, delay: delay})
        });

        address controller = ITransparentProxyFactory(proxyFactory)
            .create(
                controllerImpl,
                executor, // owner of the proxy admin
                abi.encodeWithSelector(
                    PermissionedPayloadsController.initialize.selector,
                    executor, // owner
                    guardian,
                    payloadsManager,
                    executors
                )
            );

        Ownable(executor).transferOwnership(controller);

        vm.stopBroadcast();

        // post-conditions
        PermissionedPayloadsController c = PermissionedPayloadsController(payable(controller));
        require(c.owner() == executor, "controller owner");
        require(c.guardian() == guardian, "controller guardian");
        require(c.payloadsManager() == payloadsManager, "payloadsManager");
        IPayloadsControllerCore.ExecutorConfig memory cfg =
            c.getExecutorSettingsByAccessControl(PayloadsControllerUtils.AccessControl.Level_1);
        require(cfg.executor == executor && cfg.delay == delay, "executor config");
        require(Ownable(executor).owner() == controller, "executor owner");
        address proxyAdmin = ITransparentProxyFactory(proxyFactory).getProxyAdmin(controller);
        require(Ownable(proxyAdmin).owner() == executor, "proxy admin owner");

        console.log("Executor:", executor);
        console.log("PermissionedPayloadsController impl:", controllerImpl);
        console.log("PermissionedPayloadsController proxy:", controller);
        console.log("Controller ProxyAdmin:", proxyAdmin);
    }
}

/// @notice Bitwise pool on Ink mainnet: the Super Admin Safe (Bitwise, Tydro as proposer) proposes and cancels, 24h delay
contract TydroInkBitwise is TydroInkGovernanceBase {
    // TODO: Bitwise Super Admin Safe (4/8), not created yet
    address public constant SUPER_ADMIN = address(0);

    function run() external {
        require(block.chainid == 57073, "not Ink");
        _deploy(PROXY_FACTORY_INK, SUPER_ADMIN, SUPER_ADMIN, 24 hours);
    }
}
