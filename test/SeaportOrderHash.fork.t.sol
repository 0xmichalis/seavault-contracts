// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {BaseFork} from "./helpers/BaseFork.sol";

/// @notice Pins `SeaportOrderHash` against the live Seaport deployment. Everything the vault does
///         rests on this derivation matching Seaport's byte for byte, so it is checked against the
///         real contract rather than against a second local implementation.
contract SeaportOrderHashForkTest is BaseFork {
    function setUp() public {
        forkBase();
    }

    function test_domainSeparatorMatchesSeaport() public view {
        (string memory version, bytes32 expected,) = SEAPORT.information();

        assertEq(
            SeaportOrderHash.domainSeparator(address(SEAPORT), keccak256(bytes(version))), expected
        );
    }

    function test_orderHashMatchesSeaport_singleItemListing() public view {
        OrderComponents memory order = _listing();

        assertEq(SeaportOrderHash.hash(order), SEAPORT.getOrderHash(order));
    }

    function test_orderHashMatchesSeaport_bundleWithFeeItems() public view {
        OrderComponents memory order = _listing();
        order.offer = new OfferItem[](2);
        order.offer[0] = OfferItem(ItemType.ERC721, address(0xaaaa), 1, 1, 1);
        order.offer[1] = OfferItem(ItemType.ERC1155, address(0xbbbb), 7, 3, 3);
        order.consideration = new ConsiderationItem[](3);
        order.consideration[0] = ConsiderationItem(
            ItemType.NATIVE, address(0), 0, 0.99 ether, 0.99 ether, payable(address(this))
        );
        order.consideration[1] = ConsiderationItem(
            ItemType.NATIVE, address(0), 0, 0.005 ether, 0.005 ether, payable(address(0xfee1))
        );
        order.consideration[2] = ConsiderationItem(
            ItemType.NATIVE, address(0), 0, 0.005 ether, 0.005 ether, payable(address(0xfee2))
        );

        assertEq(SeaportOrderHash.hash(order), SEAPORT.getOrderHash(order));
    }

    function test_orderHashMatchesSeaport_criteriaOffer() public view {
        OrderComponents memory order = _listing();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC20, address(0x4200), 0, 1 ether, 0.5 ether);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = ConsiderationItem(
            ItemType.ERC1155_WITH_CRITERIA,
            address(0xaaaa),
            uint256(keccak256("merkle root")),
            1,
            1,
            payable(address(this))
        );
        order.orderType = OrderType.PARTIAL_RESTRICTED;
        order.zone = address(0xf00e);
        order.zoneHash = keccak256("zone hash");

        assertEq(SeaportOrderHash.hash(order), SEAPORT.getOrderHash(order));
    }

    function test_orderHashMatchesSeaport_emptyItemArrays() public view {
        OrderComponents memory order = _listing();
        order.offer = new OfferItem[](0);
        order.consideration = new ConsiderationItem[](0);

        assertEq(SeaportOrderHash.hash(order), SEAPORT.getOrderHash(order));
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_orderHashMatchesSeaport(
        address offerer,
        address zone,
        uint8 offerItems,
        uint8 considerationItems,
        uint8 orderType,
        uint256 startTime,
        uint256 endTime,
        bytes32 zoneHash,
        uint256 salt,
        bytes32 conduitKey,
        uint256 counter
    ) public view {
        OrderComponents memory order = OrderComponents({
            offerer: offerer,
            zone: zone,
            offer: new OfferItem[](offerItems % 4),
            consideration: new ConsiderationItem[](considerationItems % 5),
            orderType: OrderType(orderType % 5),
            startTime: startTime,
            endTime: endTime,
            zoneHash: zoneHash,
            salt: salt,
            conduitKey: conduitKey,
            counter: counter
        });
        for (uint256 i; i < order.offer.length; ++i) {
            order.offer[i] = OfferItem(
                ItemType(uint8(uint256(keccak256(abi.encode(salt, i)))) % 6),
                address(uint160(uint256(keccak256(abi.encode("token", salt, i))))),
                uint256(keccak256(abi.encode("id", salt, i))),
                uint256(keccak256(abi.encode("start", salt, i))),
                uint256(keccak256(abi.encode("end", salt, i)))
            );
        }
        for (uint256 i; i < order.consideration.length; ++i) {
            order.consideration[i] = ConsiderationItem(
                ItemType(uint8(uint256(keccak256(abi.encode(counter, i)))) % 6),
                address(uint160(uint256(keccak256(abi.encode("token", counter, i))))),
                uint256(keccak256(abi.encode("id", counter, i))),
                uint256(keccak256(abi.encode("start", counter, i))),
                uint256(keccak256(abi.encode("end", counter, i))),
                payable(address(uint160(uint256(keccak256(abi.encode("recipient", counter, i))))))
            );
        }

        assertEq(SeaportOrderHash.hash(order), SEAPORT.getOrderHash(order));
    }

    function _listing() private view returns (OrderComponents memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(0xaaaa), 42, 1, 1);

        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.NATIVE, address(0), 0, 1 ether, 1 ether, payable(address(this))
        );

        return OrderComponents({
            offerer: address(this),
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.PARTIAL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            zoneHash: bytes32(0),
            salt: 0x1234,
            conduitKey: OPENSEA_CONDUIT_KEY,
            counter: 0
        });
    }
}
