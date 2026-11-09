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
 * @notice Tydro pools on Ink Sepolia: Executor + PermissionedPayloadsController in one run.
 * @dev Standalone because GovBaseScript does not support Ink Sepolia (763373) in ChainHelpers.
 * Fixes the upstream script, which calls initialize without the owner argument.
 * 4 txs: Executor, controller impl, controller proxy (initialized), Executor.transferOwnership(controller).
 */
abstract contract TydroInkGovernanceBase is Script {
    // TransparentProxyFactory deployed by the aave-v3-origin batch on Ink Sepolia (verified on Blockscout)
    address public constant PROXY_FACTORY_INK_SEPOLIA = 0xd8247C7926841337E8adf9fD9E87026992C45062;

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

/// @notice Tydro internal pool: one 1/3 Safe (Martin, Evan, Arun) proposes and cancels, 20 min delay
contract TydroInkSepolia is TydroInkGovernanceBase {
    address public constant SAFE = 0x80b0A30Dcd4A5a0e86246FAeF38A74ed40FFC6e5;

    function run() external {
        require(block.chainid == 763373, "not Ink Sepolia");
        _deploy(PROXY_FACTORY_INK_SEPOLIA, SAFE, SAFE, 20 minutes);
    }
}

/// @notice Bitwise pool: the Super Admin Safe proposes and cancels, 1h delay (prod: 24h)
contract TydroInkSepoliaBitwise is TydroInkGovernanceBase {
    address public constant SUPER_ADMIN = 0x2fD5B1C34199294a6642651587AE3dA3B837bCA8;

    function run() external {
        require(block.chainid == 763373, "not Ink Sepolia");
        _deploy(PROXY_FACTORY_INK_SEPOLIA, SUPER_ADMIN, SUPER_ADMIN, 1 hours);
    }
}
