// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {SeaportOrderHash} from "../../src/libraries/SeaportOrderHash.sol";

/// @notice The slice of Seaport the vault touches: its EIP-712 domain, counters, and the two
///         state-changing calls the vault forwards. Order validation itself is exercised against the
///         real deployment in the fork tests.
contract MockSeaport {
    string public version = "1.6";
    address public conduitController = address(0xc0de);

    /// @dev Non-zero to report a domain separator that does not match the derived one.
    bytes32 public domainSeparatorOverride;

    mapping(address offerer => uint256) public counters;
    OrderComponents[] public cancelled;
    uint256 public incrementCounterCalls;

    function information() external view returns (string memory, bytes32 domainSeparator, address) {
        return (
            version,
            domainSeparatorOverride != bytes32(0)
                ? domainSeparatorOverride
                : SeaportOrderHash.domainSeparator(address(this), keccak256(bytes(version))),
            conduitController
        );
    }

    function setDomainSeparatorOverride(bytes32 newDomainSeparator) external {
        domainSeparatorOverride = newDomainSeparator;
    }

    function getCounter(address offerer) external view returns (uint256) {
        return counters[offerer];
    }

    function cancel(OrderComponents[] calldata orders) external returns (bool) {
        for (uint256 i; i < orders.length; ++i) {
            cancelled.push(orders[i]);
        }
        return true;
    }

    function cancelledCount() external view returns (uint256) {
        return cancelled.length;
    }

    function incrementCounter() external returns (uint256) {
        ++incrementCounterCalls;
        return ++counters[msg.sender];
    }
}
