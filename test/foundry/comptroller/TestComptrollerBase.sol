pragma solidity ^0.8.0;

import {TestWrapper} from "../TestWrapper.sol";
import {Comptroller} from "union-v1.5-contracts/token/Comptroller.sol";

contract ComptrollerInternals is Comptroller {
    function getInflationIndex(
        uint256 effectiveAmount,
        uint256 inflationIndex,
        uint256 blockDelta
    ) public view returns (uint256) {
        return _getInflationIndex(effectiveAmount, inflationIndex, blockDelta);
    }

    function lookup(uint256 index) public pure returns (uint256) {
        return _lookup(index);
    }
}

contract TestComptrollerBase is TestWrapper {
    Comptroller public comptroller;
    ComptrollerInternals public comptrollerInternals;

    uint256 public halfDecayPoint = 1000000;

    function setUp() public virtual {
        address logic = address(new Comptroller());

        deployMocks();

        uint256 halfDecayPoint = 1000000;

        comptroller = Comptroller(
            deployProxy(
                logic,
                abi.encodeWithSignature("__Comptroller_init(address,uint256)", unionTokenMock, halfDecayPoint)
            )
        );

        comptroller.setUserManager(address(daiMock), address(userManagerMock));
    }

    function deployComtrollerExposedInternals() public {
        address logic = address(new ComptrollerInternals());

        comptrollerInternals = ComptrollerInternals(
            deployProxy(
                logic,
                abi.encodeWithSignature("__Comptroller_init(address,uint256)", unionTokenMock, halfDecayPoint)
            )
        );
    }
}
