// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {OfferItem, OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../../src/Seavault.sol";

/// @notice Builds the roots and witnesses used by fixtures with one or two collections.
library PolicyFixture {
    struct Rule {
        address collection;
        uint256 floor;
        uint256 ceiling;
    }

    /// @dev Deterministic for test vectors. A real keeper generates unpredictable salts.
    function _salt(Rule memory rule) private pure returns (bytes32) {
        return bytes32(uint256(uint160(rule.collection)));
    }

    function leaf(Rule memory rule) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leafPreimage(rule)));
    }

    function usdcLeaf(Rule memory rule) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_leafPreimage(rule), hex"01"));
    }

    function _leafPreimage(Rule memory rule) private pure returns (bytes32) {
        return keccak256(abi.encode(rule.collection, rule.floor, rule.ceiling, _salt(rule)));
    }

    function root(Rule memory first, Rule memory second) internal pure returns (bytes32) {
        return second.collection == address(0)
            ? leaf(first)
            : Hashes.commutativeKeccak256(leaf(first), leaf(second));
    }

    function single(Rule memory rule) internal pure returns (Seavault.CollectionWitness[] memory) {
        Rule memory absent;
        return _witnesses(rule, absent, true, false);
    }

    function withSibling(Rule memory rule, bytes32 sibling)
        internal
        pure
        returns (Seavault.CollectionWitness[] memory witnesses)
    {
        witnesses = single(rule);
        witnesses[0].siblings = new bytes32[](1);
        witnesses[0].siblings[0] = sibling;
    }

    function forOrder(Rule memory first, Rule memory second, OrderComponents memory order)
        internal
        pure
        returns (Seavault.CollectionWitness[] memory)
    {
        if (order.offer.length == 0 || order.offer[0].itemType != ItemType.ERC20) {
            return forOfferItems(first, second, order.offer);
        }

        bool usesFirst;
        bool usesSecond;
        for (uint256 i; i < order.consideration.length; ++i) {
            if (order.consideration[i].itemType < ItemType.ERC721) continue;
            address collection = order.consideration[i].token;
            if (collection == first.collection) usesFirst = true;
            if (collection == second.collection) usesSecond = true;
        }
        return _witnesses(first, second, usesFirst, usesSecond);
    }

    function forOfferItems(Rule memory first, Rule memory second, OfferItem[] memory items)
        internal
        pure
        returns (Seavault.CollectionWitness[] memory)
    {
        bool usesFirst;
        bool usesSecond;
        for (uint256 i; i < items.length; ++i) {
            if (items[i].token == first.collection) usesFirst = true;
            if (items[i].token == second.collection && second.collection != address(0)) {
                usesSecond = true;
            }
        }
        return _witnesses(first, second, usesFirst, usesSecond);
    }

    function _witnesses(Rule memory first, Rule memory second, bool usesFirst, bool usesSecond)
        private
        pure
        returns (Seavault.CollectionWitness[] memory witnesses)
    {
        witnesses = new Seavault.CollectionWitness[]((usesFirst ? 1 : 0) + (usesSecond ? 1 : 0));
        if (usesFirst) witnesses[0] = _witness(first, second);
        if (usesSecond) {
            if (usesFirst && first.collection > second.collection) {
                witnesses[1] = witnesses[0];
                witnesses[0] = _witness(second, first);
            } else {
                witnesses[usesFirst ? 1 : 0] = _witness(second, first);
            }
        }
    }

    function _witness(Rule memory rule, Rule memory other)
        private
        pure
        returns (Seavault.CollectionWitness memory)
    {
        bytes32[] memory siblings = new bytes32[](other.collection == address(0) ? 0 : 1);
        if (siblings.length != 0) siblings[0] = leaf(other);
        return Seavault.CollectionWitness(
            rule.collection, rule.floor, rule.ceiling, _salt(rule), siblings
        );
    }
}
