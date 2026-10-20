// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice OpenSea's gasless cancel: the offerer signs `OrderHash(bytes32 orderHash)` under Seaport's
///         domain, and the vault vouches for that signature when its keeper made it.
contract ListoorVaultCancellationTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;
    bytes32 internal constant ORDER_HASH = keccak256("an order");

    /// @dev Pinned against forge's own EIP-712 encoder, fed the typed data OpenSea's SDK signs.
    function test_cancellationDigestIsWhatOpenSeaHasTheOffererSign() public view {
        string memory typedData = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"OrderHash":[{"name":"orderHash","type":"bytes32"}]},"primaryType":"OrderHash",',
            '"domain":{"name":"Seaport","version":"1.6","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(seaport)),
            '"},"message":{"orderHash":"',
            vm.toString(ORDER_HASH),
            '"}}'
        );

        assertEq(vault.cancellationDigest(ORDER_HASH), vm.eip712HashTypedData(typedData));
    }

    function test_vouchesForTheKeepersCancellation() public view {
        assertEq(validateCancellation(SeaportOrderHash.hash(listing(FLOOR)), keeperPk), MAGIC_VALUE);
    }

    /// @dev Cancelling has to keep working through a lapse, like every other way out.
    function test_vouchesForCancellationsWhileLapsed() public {
        subscriptions.set(false, 0.01 ether);

        assertEq(validateCancellation(ORDER_HASH, keeperPk), MAGIC_VALUE);
    }

    function test_rejectsCancellationSignedBySomeoneElse() public {
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        bytes32 digest = vault.cancellationDigest(ORDER_HASH);
        bytes memory signature = cancellationSignature(ORDER_HASH, attackerPk);

        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vault.isValidSignature(digest, signature);
    }

    /// @dev A cancellation sign-off must never pass as approval of the order it cancels, in either
    ///      encoding.
    function test_cancellationNeverApprovesTheOrder() public {
        OrderComponents memory order = listing(FLOOR);
        bytes32 orderDigest = digestOf(order);
        bytes32 orderHash = SeaportOrderHash.hash(order);
        bytes memory asCancellation = cancellationSignature(orderHash, keeperPk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keeperPk, vault.cancellationDigest(orderHash));
        bytes memory asOrder = abi.encode(order, abi.encodePacked(r, s, v));

        vm.expectRevert();
        vault.isValidSignature(orderDigest, asCancellation);

        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vault.isValidSignature(orderDigest, asOrder);
    }

    function validateCancellation(bytes32 orderHash, uint256 signerPk)
        internal
        view
        returns (bytes4)
    {
        return vault.isValidSignature(
            vault.cancellationDigest(orderHash), cancellationSignature(orderHash, signerPk)
        );
    }

    /// @dev What the keeper hands OpenSea as the offerer signature.
    function cancellationSignature(bytes32 orderHash, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, vault.cancellationDigest(orderHash));
        return abi.encode(orderHash, abi.encodePacked(r, s, v));
    }
}
