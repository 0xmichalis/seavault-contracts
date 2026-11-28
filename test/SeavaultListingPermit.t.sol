// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {OfferItem, OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../src/Seavault.sol";
import {MockOwnerWallet} from "./SeavaultOpenSeaLogin.t.sol";
import {ListingPermitFixture} from "./helpers/ListingPermitFixture.sol";
import {PolicyFixture} from "./helpers/PolicyFixture.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

contract SeavaultListingPermitTest is VaultTest {
    bytes4 private constant MAGIC_VALUE = IERC1271.isValidSignature.selector;
    uint256 private ownerPk;

    function setUp() public override {
        super.setUp();
        (, ownerPk) = makeAddrAndKey("owner");
        setNftPolicy(0, CEILING);
    }

    function test_permitCanBeUsedToRepriceAtOrAboveFloor() public view {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        assertEq(_validate(order, permits), MAGIC_VALUE);

        order.salt++;
        order.consideration[0] = payment(address(weth), FLOOR * 2, address(vault));
        assertEq(_validate(order, permits), MAGIC_VALUE);
    }

    function test_permitMatchesWalletTypedData() public view {
        OrderComponents memory order = _listing(FLOOR);
        string memory typedData = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"ListingPermit":[{"name":"collection","type":"address"},{"name":"tokenId","type":"uint256"},',
            '{"name":"currency","type":"address"},{"name":"floorPerUnit","type":"uint256"},',
            '{"name":"deadline","type":"uint256"},{"name":"counter","type":"uint256"}]},',
            '"primaryType":"ListingPermit","domain":{"name":"Seavault","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(vault)),
            '"},"message":{"collection":"',
            vm.toString(address(nft)),
            '","tokenId":',
            vm.toString(TOKEN_ID),
            ',"currency":"',
            vm.toString(address(0)),
            '","floorPerUnit":"',
            vm.toString(FLOOR),
            '","deadline":',
            vm.toString(order.endTime),
            ',"counter":',
            vm.toString(order.counter),
            "}}"
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, vm.eip712HashTypedData(typedData));
        Seavault.ListingPermit[] memory permits = new Seavault.ListingPermit[](1);
        permits[0] = Seavault.ListingPermit(FLOOR, order.endTime, abi.encodePacked(r, s, v));
        assertEq(_validate(order, permits), MAGIC_VALUE);
    }

    function test_rejectsListingWithoutPermitForZeroFloor() public {
        OrderComponents memory order = _listing(FLOOR);
        expectRevertOn(
            abi.encodeWithSelector(Seavault.CollectionNotListable.selector, address(nft)), order
        );
    }

    function test_rejectsPermitWhenCollectionFloorIsInEffect() public {
        setNftPolicy(FLOOR, CEILING);
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR / 2);

        vm.expectRevert(Seavault.InvalidListingPermit.selector);
        _validate(order, permits);
        assertEq(validate(order), MAGIC_VALUE);
    }

    function test_permitStillRequiresAProvenCollectionCeiling() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        bytes memory payload = _payload(order, permits, new Seavault.CollectionWitness[](0));

        vm.expectRevert(Seavault.InvalidCollectionWitness.selector);
        vault.isValidSignature(digestOf(order), payload);
    }

    function test_proceedsMustClearPermitFloor() public {
        OrderComponents memory order = _listing(FLOOR - 1);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        vm.expectRevert(abi.encodeWithSelector(Seavault.PriceBelowFloor.selector, FLOOR, FLOOR - 1));
        _validate(order, permits);
    }

    /// @dev Permit floors are raised to the ceiling, so a permit cannot authorize a loss on resale.
    function test_ceilingRaisesPermitFloor() public {
        OrderComponents memory order = _listing(CEILING - 1);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, CEILING / 2);
        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PriceBelowFloor.selector, CEILING, CEILING - 1)
        );
        _validate(order, permits);

        order.consideration[0] = payment(address(0), CEILING, address(vault));
        assertEq(_validate(order, permits), MAGIC_VALUE);
    }

    function test_rejectsZeroPermitFloor() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, 0);
        vm.expectRevert(Seavault.InvalidListingPermit.selector);
        _validate(order, permits);
    }

    function test_rejectsPermitForAnotherTokenOrTamperedFloor() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        order.offer[0].identifierOrCriteria++;
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);

        order.offer[0].identifierOrCriteria--;
        permits[0].floorPerUnit--;
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);
    }

    function test_rejectsKeeperAuthorizationInPlaceOfOwner() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        bytes32 digest = ListingPermitFixture.digest(
            address(vault), order.offer[0], address(0), FLOOR, order.endTime, order.counter
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keeperPk, digest);
        permits[0].signature = abi.encodePacked(r, s, v);
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);
    }

    function test_acceptsContractOwnerAuthorization() public {
        MockOwnerWallet wallet = new MockOwnerWallet(owner);
        vm.prank(owner);
        vault.transferOwnership(address(wallet));
        vm.prank(address(wallet));
        vault.acceptOwnership();

        OrderComponents memory order = _listing(FLOOR);
        assertEq(_validate(order, _nativePermit(order, FLOOR)), MAGIC_VALUE);
    }

    function test_usdcRequiresItsOwnPermit() public {
        bytes32 previous = vault.policyRoot();
        PolicyFixture.Rule memory usdcPolicy = PolicyFixture.Rule(address(nft), 0, 50e6);
        vm.prank(owner);
        vault.setPolicyRoot(previous, PolicyFixture.usdcLeaf(usdcPolicy));
        Seavault.CollectionWitness[] memory witnesses = PolicyFixture.single(usdcPolicy);

        OrderComponents memory order = _listing(100e6);
        order.consideration[0] = payment(usdc, 100e6, address(vault));
        Seavault.ListingPermit[] memory permits = _nativePermit(order, 100e6);

        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        vault.isValidSignature(digestOf(order), _payload(order, permits, witnesses));

        permits[0] = _permit(order, order.offer[0], usdc, 100e6);
        assertEq(
            vault.isValidSignature(digestOf(order), _payload(order, permits, witnesses)),
            MAGIC_VALUE
        );
    }

    function test_everyZeroFloorItemInBundleRequiresItsPermit() public {
        OrderComponents memory order = _listing(FLOOR * 3);
        OfferItem memory first = order.offer[0];
        order.offer = new OfferItem[](3);
        order.offer[0] = first;
        order.offer[1] = OfferItem(ItemType.ERC1155, address(edition), EDITION_ID, 1, 1);
        order.offer[2] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID + 1, 1, 1);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.CollectionNotListable.selector, address(nft))
        );
        _validate(order, permits);

        permits = new Seavault.ListingPermit[](2);
        permits[0] = _permit(order, order.offer[0], address(0), FLOOR);
        permits[1] = _permit(order, order.offer[2], address(0), FLOOR);
        assertEq(_validate(order, permits), MAGIC_VALUE);
    }

    function test_orderCannotOutlivePermitEvenByOneSecond() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        assertEq(_validate(order, permits), MAGIC_VALUE);
        order.endTime++;
        vm.expectRevert(Seavault.InvalidListingPermit.selector);
        _validate(order, permits);
    }

    function test_rejectsExpiredPermit() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        vm.warp(order.endTime);
        vm.expectRevert(Seavault.InvalidListingPermit.selector);
        _validate(order, permits);
    }

    function test_counterBumpInvalidatesPermitEvenForNewOrder() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        vm.prank(owner);
        vault.incrementCounter();

        vm.expectRevert(Seavault.InvalidListingPermit.selector);
        _validate(order, permits);
        order.counter = seaport.getCounter(address(vault));
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);

        assertEq(_validate(order, _nativePermit(order, FLOOR)), MAGIC_VALUE);
    }

    function test_rejectsPermitFromAnotherChain() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault.ListingPermit[] memory permits = _nativePermit(order, FLOOR);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);
    }

    function test_rejectsPermitForAnotherVault() public {
        OrderComponents memory order = _listing(FLOOR);
        Seavault other = newVault(owner, keeper, keccak256("another vault"));
        bytes32 digest = ListingPermitFixture.digest(
            address(other), order.offer[0], address(0), FLOOR, order.endTime, order.counter
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        Seavault.ListingPermit[] memory permits = new Seavault.ListingPermit[](1);
        permits[0] = Seavault.ListingPermit(FLOOR, order.endTime, abi.encodePacked(r, s, v));
        vm.expectRevert(Seavault.UnauthorizedSigner.selector);
        _validate(order, permits);
    }

    function _listing(uint256 price) private view returns (OrderComponents memory order) {
        order = listing(price);
        order.counter = seaport.getCounter(address(vault));
    }

    function _nativePermit(OrderComponents memory order, uint256 floorPerUnit)
        private
        view
        returns (Seavault.ListingPermit[] memory permits)
    {
        permits = new Seavault.ListingPermit[](1);
        permits[0] = _permit(order, order.offer[0], address(0), floorPerUnit);
    }

    function _permit(
        OrderComponents memory order,
        OfferItem memory item,
        address currency,
        uint256 floorPerUnit
    ) private view returns (Seavault.ListingPermit memory) {
        bytes32 digest = ListingPermitFixture.digest(
            address(vault), item, currency, floorPerUnit, order.endTime, order.counter
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return Seavault.ListingPermit(floorPerUnit, order.endTime, abi.encodePacked(r, s, v));
    }

    function _validate(OrderComponents memory order, Seavault.ListingPermit[] memory permits)
        private
        view
        returns (bytes4)
    {
        return
            vault.isValidSignature(
                digestOf(order), _payload(order, permits, policyWitnesses(order))
            );
    }

    function _payload(
        OrderComponents memory order,
        Seavault.ListingPermit[] memory permits,
        Seavault.CollectionWitness[] memory witnesses
    ) private view returns (bytes memory) {
        return abi.encode(order, abi.encode(signatureFor(order, keeperPk), permits), witnesses);
    }
}
