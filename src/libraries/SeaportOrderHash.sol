// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

/// @title SeaportOrderHash
/// @custom:security-contact security@kazani.ch
/// @notice Re-derives the EIP-712 digest that Seaport produces for an order.
/// @dev A contract offerer only receives the digest in `isValidSignature`, which says nothing about
///      what is being sold and for how much. Re-deriving the digest from order components supplied
///      alongside the signature proves those components are the ones Seaport is validating, which is
///      what makes on-chain policy enforcement possible. Mirrors Seaport's `_deriveOrderHash`,
///      `_deriveDomainSeparator` and `_deriveEIP712Digest`; pinned against the live contract by
///      `SeaportOrderHash.fork.t.sol`.
library SeaportOrderHash {
    bytes32 internal constant EIP_712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @dev Seaport's EIP-712 domain name, identical across all versions.
    bytes32 internal constant SEAPORT_NAME_HASH = keccak256("Seaport");

    bytes32 internal constant OFFER_ITEM_TYPEHASH = keccak256(
        "OfferItem(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount)"
    );

    bytes32 internal constant CONSIDERATION_ITEM_TYPEHASH = keccak256(
        "ConsiderationItem(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount,address recipient)"
    );

    /// @dev Referenced types are appended alphabetically, per EIP-712.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "OrderComponents(address offerer,address zone,OfferItem[] offer,ConsiderationItem[] consideration,uint8 orderType,uint256 startTime,uint256 endTime,bytes32 zoneHash,uint256 salt,bytes32 conduitKey,uint256 counter)ConsiderationItem(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount,address recipient)OfferItem(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount)"
    );

    /// @dev What OpenSea has an offerer sign, under Seaport's domain, to cancel an order without gas.
    bytes32 internal constant ORDER_HASH_TYPEHASH = keccak256("OrderHash(bytes32 orderHash)");

    /// @notice Derives Seaport's domain separator for the current chain.
    /// @dev Derived rather than cached because Seaport itself re-derives it when `block.chainid`
    ///      changes, so a cached copy would go stale on a chain fork.
    function domainSeparator(address seaport, bytes32 versionHash) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP_712_DOMAIN_TYPEHASH, SEAPORT_NAME_HASH, versionHash, block.chainid, seaport
            )
        );
    }

    /// @notice Hashes order components into a Seaport order hash.
    /// @dev The struct encoding is assembled in chunks because encoding all twelve members in one
    ///      `abi.encode` exhausts the stack. Every member is a static type, so concatenating the
    ///      chunks yields the same bytes as a single call would.
    function hash(OrderComponents memory order) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(ORDER_TYPEHASH, order.offerer, order.zone),
                abi.encode(_hashOffer(order.offer), _hashConsideration(order.consideration)),
                abi.encode(order.orderType, order.startTime, order.endTime, order.zoneHash),
                abi.encode(order.salt, order.conduitKey, order.counter)
            )
        );
    }

    function _hashOffer(OfferItem[] memory offer) private pure returns (bytes32) {
        bytes32[] memory itemHashes = new bytes32[](offer.length);
        for (uint256 i; i < offer.length; ++i) {
            OfferItem memory item = offer[i];
            itemHashes[i] = keccak256(
                abi.encode(
                    OFFER_ITEM_TYPEHASH,
                    item.itemType,
                    item.token,
                    item.identifierOrCriteria,
                    item.startAmount,
                    item.endAmount
                )
            );
        }
        return keccak256(abi.encodePacked(itemHashes));
    }

    function _hashConsideration(ConsiderationItem[] memory consideration)
        private
        pure
        returns (bytes32)
    {
        bytes32[] memory itemHashes = new bytes32[](consideration.length);
        for (uint256 i; i < consideration.length; ++i) {
            ConsiderationItem memory item = consideration[i];
            itemHashes[i] = keccak256(
                abi.encode(
                    CONSIDERATION_ITEM_TYPEHASH,
                    item.itemType,
                    item.token,
                    item.identifierOrCriteria,
                    item.startAmount,
                    item.endAmount,
                    item.recipient
                )
            );
        }
        return keccak256(abi.encodePacked(itemHashes));
    }

    /// @notice Derives the EIP-712 digest Seaport signs over for the given order.
    function digest(bytes32 separator, OrderComponents memory order)
        internal
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(separator, hash(order));
    }

    /// @notice Derives the EIP-712 digest OpenSea has an offerer sign to cancel an order offchain.
    /// @dev Its struct is `OrderHash`, not `OrderComponents`, so it never equals an order digest.
    function cancellationDigest(bytes32 separator, bytes32 orderHash)
        internal
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(
            separator, keccak256(abi.encode(ORDER_HASH_TYPEHASH, orderHash))
        );
    }
}
