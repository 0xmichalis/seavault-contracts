// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BulkOrderProof_lengthAdjustmentBeforeMask,
    BulkOrderProof_lengthRangeAfterMask,
    BulkOrderProof_minSize,
    BulkOrderProof_rangeSize
} from "seaport-types/src/lib/ConsiderationConstants.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Seaport reads signatures whose length falls in a specific window as bulk-order proofs and
///         derives a different digest from them, which would make every vault order unfillable. The
///         encoding must never produce such a length.
contract SignatureEncodingTest is VaultTest {
    function test_realOrderPayloadsSitOutsideTheBulkWindow() public view {
        uint256 aboveWindow = BulkOrderProof_minSize + BulkOrderProof_rangeSize;

        assertGt(payloadFor(listing(FLOOR), keeperPk).length, aboveWindow);
        assertGt(payloadFor(offer(CEILING), keeperPk).length, aboveWindow);
    }

    function testFuzz_payloadIsNeverMistakenForABulkSignature(
        uint8 offerItems,
        uint8 considerationItems
    ) public view {
        OrderComponents memory order = emptyOrder();
        order.offer = new OfferItem[](offerItems % 24);
        order.consideration = new ConsiderationItem[](considerationItems % 24);

        uint256 length = payloadFor(order, keeperPk).length;

        // Every ABI-encoded payload is word-aligned, and the window only covers lengths that are 29
        // or 30 bytes past a word boundary.
        assertEq(length % 32, 0);
        assertFalse(_isBulkOrderSize(length));
    }

    /// @dev Mirrors Seaport's `_isValidBulkOrderSize`, including its wrapping arithmetic.
    function _isBulkOrderSize(uint256 signatureLength) private pure returns (bool) {
        unchecked {
            return signatureLength - BulkOrderProof_minSize < BulkOrderProof_rangeSize
                && (signatureLength - BulkOrderProof_lengthAdjustmentBeforeMask) % 32
                    < BulkOrderProof_lengthRangeAfterMask;
        }
    }
}
