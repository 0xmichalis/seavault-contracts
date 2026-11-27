// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {OfferItem, OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../src/Seavault.sol";
import {PolicyFixture} from "./helpers/PolicyFixture.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

contract SeavaultPolicyTest is VaultTest {
    uint256 private constant USDC_FLOOR = 100e6;
    uint256 private constant USDC_CEILING = 110e6;

    function test_rootChangeIsAtomicWithCounterBump() public {
        bytes32 previous = vault.policyRoot();
        bytes32 next = bytes32(uint256(1));
        uint256 counterBefore = seaport.getCounter(address(vault));

        vm.expectEmit(true, false, false, false, address(vault));
        emit Seavault.PolicyRootUpdated(next);
        vm.prank(owner);
        vault.setPolicyRoot(previous, next);

        assertEq(vault.policyRoot(), next);
        assertEq(seaport.getCounter(address(vault)), counterBefore + 1);
    }

    function test_staleRootUpdateLeavesPolicyAndCounterUntouched() public {
        bytes32 active = vault.policyRoot();
        uint256 counterBefore = seaport.getCounter(address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PolicyRootMismatch.selector, bytes32(0), active)
        );
        vm.prank(owner);
        vault.setPolicyRoot(bytes32(0), bytes32(uint256(1)));

        assertEq(vault.policyRoot(), active);
        assertEq(seaport.getCounter(address(vault)), counterBefore);
    }

    function test_sameRootDoesNotRetireOrders() public {
        bytes32 active = vault.policyRoot();
        uint256 counterBefore = seaport.getCounter(address(vault));
        vm.prank(owner);
        vault.setPolicyRoot(active, active);
        assertEq(seaport.getCounter(address(vault)), counterBefore);
    }

    function test_oldWitnessFailsAfterRootChange() public {
        OrderComponents memory order = listing(FLOOR);
        bytes32 digest = digestOf(order);
        bytes memory stale = payloadFor(order, keeperPk);
        setNftPolicy(FLOOR / 2, CEILING);

        vm.expectRevert(Seavault.InvalidCollectionWitness.selector);
        vault.isValidSignature(digest, stale);
        assertEq(validate(order), IERC1271.isValidSignature.selector);
    }

    function test_zeroRootDisablesOrdersAndLeavesCancellationAvailable() public {
        bytes32 active = vault.policyRoot();
        vm.prank(owner);
        vault.setPolicyRoot(active, bytes32(0));

        expectRevertOn(
            abi.encodeWithSelector(Seavault.InvalidCollectionWitness.selector), listing(FLOOR)
        );
        bytes32 orderHash = keccak256("order to cancel");
        bytes32 digest = vault.cancellationDigest(orderHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keeperPk, digest);
        assertEq(
            vault.isValidSignature(digest, abi.encode(orderHash, abi.encodePacked(r, s, v))),
            IERC1271.isValidSignature.selector
        );
    }

    function test_witnessCannotBeUsedForAnotherCollection() public {
        Seavault.CollectionWitness[] memory witnesses = policyWitnesses(listing(FLOOR));
        OrderComponents memory order = listing(FLOOR);
        order.offer[0].token = address(edition);
        _expectWitnessRejection(order, witnesses);
    }

    function test_usdcAndNativeProofsAreCurrencySpecific() public {
        (
            Seavault.CollectionWitness[] memory nativeWitnesses,
            Seavault.CollectionWitness[] memory usdcWitnesses
        ) = _activateBothCurrencies();

        OrderComponents memory nativeOrder = listing(FLOOR);
        OrderComponents memory usdcOrder = listing(USDC_CEILING);
        usdcOrder.consideration[0] = payment(usdc, USDC_CEILING, address(vault));

        _assertValid(nativeOrder, nativeWitnesses);
        _assertValid(usdcOrder, usdcWitnesses);
        _expectWitnessRejection(nativeOrder, usdcWitnesses);
        _expectWitnessRejection(usdcOrder, nativeWitnesses);
    }

    function test_enforcesUsdcCeilingForListingsAndBids() public {
        (, Seavault.CollectionWitness[] memory witnesses) = _activateBothCurrencies();

        OrderComponents memory sale = listing(USDC_CEILING - 1);
        sale.consideration[0] = payment(usdc, USDC_CEILING - 1, address(vault));
        _expectValidationRejection(
            abi.encodeWithSelector(
                Seavault.PriceBelowFloor.selector, USDC_CEILING, USDC_CEILING - 1
            ),
            sale,
            witnesses
        );

        OrderComponents memory bid = offer(USDC_CEILING + 1);
        bid.offer[0].token = usdc;
        _expectValidationRejection(
            abi.encodeWithSelector(
                Seavault.PriceAboveCeiling.selector, USDC_CEILING, USDC_CEILING + 1
            ),
            bid,
            witnesses
        );
    }

    function test_rejectsNativeAndWrappedFeesOnUsdcOrders() public {
        (, Seavault.CollectionWitness[] memory witnesses) = _activateBothCurrencies();
        OrderComponents memory sale = listing(USDC_CEILING);
        sale.consideration[0] = payment(usdc, USDC_CEILING, address(vault));
        sale.consideration = withFee(sale.consideration, address(0), 1);
        _expectValidationRejection(
            abi.encodeWithSelector(Seavault.PaymentTokenNotAllowed.selector, address(0)),
            sale,
            witnesses
        );

        OrderComponents memory bid = offer(USDC_CEILING);
        bid.offer[0].token = usdc;
        bid.consideration = withFee(bid.consideration, address(weth), 1);
        _expectValidationRejection(
            abi.encodeWithSelector(Seavault.PaymentTokenNotAllowed.selector, address(weth)),
            bid,
            witnesses
        );
    }

    function test_rejectsTamperedFloorSaltAndProof() public {
        OrderComponents memory order = listing(FLOOR);
        Seavault.CollectionWitness[] memory witnesses = policyWitnesses(order);
        witnesses[0].floor -= 1;
        _expectWitnessRejection(order, witnesses);

        witnesses[0].floor = FLOOR;
        bytes32 salt = witnesses[0].salt;
        witnesses[0].salt = bytes32(0);
        _expectWitnessRejection(order, witnesses);

        witnesses[0].salt = salt;
        witnesses[0].siblings[0] = bytes32(0);
        _expectWitnessRejection(order, witnesses);
    }

    function test_tokenFloorCannotBeUsedWithoutAProvenCeiling() public {
        vm.prank(owner);
        vault.setTokenListingFloor(address(nft), TOKEN_ID, 1);
        _expectWitnessRejection(listing(1), new Seavault.CollectionWitness[](0));
    }

    function test_requiresSortedDistinctWitnesses() public {
        OrderComponents memory order = listing(2 * FLOOR);
        OfferItem memory first = order.offer[0];
        order.offer = new OfferItem[](2);
        order.offer[0] = first;
        order.offer[1] = OfferItem(ItemType.ERC1155, address(edition), EDITION_ID, 1, 1);

        Seavault.CollectionWitness[] memory witnesses = policyWitnesses(order);
        _assertValid(order, witnesses);

        Seavault.CollectionWitness memory earlier = witnesses[0];
        witnesses[0] = witnesses[1];
        witnesses[1] = earlier;
        _expectWitnessRejection(order, witnesses);

        witnesses[0] = earlier;
        _expectWitnessRejection(order, witnesses);
    }

    function test_acceptsDepthTenAndRejectsDepthEleven() public {
        OrderComponents memory order = listing(FLOOR);
        Seavault.CollectionWitness[] memory witnesses = PolicyFixture.single(nftPolicy);
        witnesses[0].siblings = new bytes32[](10);
        _activateWitness(witnesses[0]);
        _assertValid(order, witnesses);

        witnesses[0].siblings = new bytes32[](11);
        _activateWitness(witnesses[0]);
        _expectWitnessRejection(order, witnesses);
    }

    /// @dev The third leaf in this three-collection snapshot advances one level without a sibling.
    function test_verifiesPortableSnapshotVector() public {
        bytes32 active = vault.policyRoot();
        bytes32 root = 0xa02047e4def9df245b7ffe06d5954e65703a6c4bdd386173683f33d59e7bec0e;
        vm.prank(owner);
        vault.setPolicyRoot(active, root);

        OrderComponents memory order = listing(7 ether);
        order.offer[0].token = address(0x3333);
        Seavault.CollectionWitness[] memory witnesses =
            PolicyFixture.single(PolicyFixture.Rule(address(0x3333), 7 ether, 6 ether));
        witnesses[0].siblings = new bytes32[](1);
        witnesses[0].siblings[0] =
        0xdc20909cad0460de9b796cf46f1f9679ae4ad79cf397cbbdd84a65da7964e78f;
        _assertValid(order, witnesses);
    }

    function _activateWitness(Seavault.CollectionWitness memory witness) private {
        bytes32 root = PolicyFixture.leaf(nftPolicy);
        for (uint256 i; i < witness.siblings.length; ++i) {
            root = Hashes.commutativeKeccak256(root, witness.siblings[i]);
        }
        bytes32 active = vault.policyRoot();
        vm.prank(owner);
        vault.setPolicyRoot(active, root);
    }

    function _activateBothCurrencies()
        private
        returns (
            Seavault.CollectionWitness[] memory nativeWitnesses,
            Seavault.CollectionWitness[] memory usdcWitnesses
        )
    {
        PolicyFixture.Rule memory usdcRule =
            PolicyFixture.Rule(address(nft), USDC_FLOOR, USDC_CEILING);
        bytes32 nativeLeaf = PolicyFixture.leaf(nftPolicy);
        bytes32 usdcLeaf = PolicyFixture.usdcLeaf(usdcRule);
        bytes32 previous = vault.policyRoot();
        vm.prank(owner);
        vault.setPolicyRoot(previous, Hashes.commutativeKeccak256(nativeLeaf, usdcLeaf));
        return (
            PolicyFixture.withSibling(nftPolicy, usdcLeaf),
            PolicyFixture.withSibling(usdcRule, nativeLeaf)
        );
    }

    function _assertValid(
        OrderComponents memory order,
        Seavault.CollectionWitness[] memory witnesses
    ) private view {
        assertEq(
            vault.isValidSignature(
                digestOf(order), abi.encode(order, signatureFor(order, keeperPk), witnesses)
            ),
            IERC1271.isValidSignature.selector
        );
    }

    function _expectWitnessRejection(
        OrderComponents memory order,
        Seavault.CollectionWitness[] memory witnesses
    ) private {
        _expectValidationRejection(
            abi.encodeWithSelector(Seavault.InvalidCollectionWitness.selector), order, witnesses
        );
    }

    function _expectValidationRejection(
        bytes memory reason,
        OrderComponents memory order,
        Seavault.CollectionWitness[] memory witnesses
    ) private {
        bytes32 digest = digestOf(order);
        bytes memory payload = abi.encode(order, signatureFor(order, keeperPk), witnesses);
        vm.expectRevert(reason);
        vault.isValidSignature(digest, payload);
    }
}
