// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OfferItem} from "seaport-types/src/lib/ConsiderationStructs.sol";

library ListingPermitFixture {
    function digest(
        address vault,
        OfferItem memory item,
        address currency,
        uint256 floorPerUnit,
        uint256 deadline,
        uint256 counter
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Seavault"),
                keccak256("1"),
                block.chainid,
                vault
            )
        );
        bytes32 permit = keccak256(
            abi.encode(
                keccak256(
                    "ListingPermit(address collection,uint256 tokenId,address currency,uint256 floorPerUnit,uint256 deadline,uint256 counter)"
                ),
                item.token,
                item.identifierOrCriteria,
                currency,
                floorPerUnit,
                deadline,
                counter
            )
        );
        return MessageHashUtils.toTypedDataHash(domain, permit);
    }
}
