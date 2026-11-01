// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Owner wallet that is itself a contract, e.g. a multisig holding the vault.
contract MockOwnerWallet is IERC1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        return ECDSA.recover(hash, signature) == signer ? this.isValidSignature.selector : bytes4(0);
    }
}

/// @notice OpenSea sign-in as the vault: OpenSea asks the vault to vouch for a Sign-In with Ethereum
///         message naming it, and the vault does so when its owner approved that exact message.
contract ListoorVaultOpenSeaLoginTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    string internal constant STATEMENT =
        "Click to sign in and accept the Platform Terms of Service (https://opensea.io/tos) and Privacy Policy (https://opensea.io/privacy).";

    uint256 internal ownerPk;
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        (, ownerPk) = makeAddrAndKey("owner");
        vm.warp(1_793_552_419);
        deadline = block.timestamp + 10 minutes;
    }

    /*//////////////////////////////////////////////////////////////
                               ACCEPTANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev The message opensea.io asked a wallet to sign on 2026-11-01, naming this vault.
    function test_vouchesForTheWebsiteSignIn() public view {
        assertEq(signIn(vault, websiteBody(), ownerPk), MAGIC_VALUE);
    }

    /// @dev OpenSea's SDK builds the same message without the URI's trailing slash.
    function test_vouchesForTheSdkSignIn() public view {
        assertEq(signIn(vault, sdkBody(), ownerPk), MAGIC_VALUE);
    }

    /// @dev Pins the owner's approval against forge's own EIP-712 encoder, fed the typed data a
    ///      wallet is asked to sign.
    function test_approvalIsTheTypedDataTheOwnerSigns() public view {
        string memory body = "\nURI: https://opensea.io/\nNonce: abc123";
        string memory escapedMessage = string.concat(
            "opensea.io wants you to sign in with your Ethereum account:\\n",
            Strings.toChecksumHexString(address(vault)),
            "\\n\\nURI: https://opensea.io/\\nNonce: abc123"
        );
        string memory typedData = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"OpenSeaLogin":[{"name":"message","type":"string"},{"name":"deadline","type":"uint256"}]},',
            '"primaryType":"OpenSeaLogin","domain":{"name":"Seavault","version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(vault)),
            '"},"message":{"message":"',
            escapedMessage,
            '","deadline":',
            vm.toString(deadline),
            "}}"
        );
        assertEq(
            approvalHash(vault, fullMessage(vault, body), deadline),
            vm.eip712HashTypedData(typedData)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, vm.eip712HashTypedData(typedData));
        bytes memory signature =
            abi.encode(vault.OPENSEA_LOGIN_TAG(), bytes(body), deadline, abi.encodePacked(r, s, v));
        assertEq(
            vault.isValidSignature(personalSignDigest(fullMessage(vault, body)), signature),
            MAGIC_VALUE
        );
    }

    function test_vouchesUpToAndIncludingTheDeadline() public {
        bytes32 digest = personalSignDigest(fullMessage(vault, websiteBody()));
        bytes memory signature = envelope(vault, websiteBody(), deadline, ownerPk);

        vm.warp(deadline);
        assertEq(vault.isValidSignature(digest, signature), MAGIC_VALUE);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.OpenSeaLoginExpired.selector, deadline));
        vault.isValidSignature(digest, signature);
    }

    /// @dev Signing in is an owner action, so it keeps working while the keeper is cut off.
    function test_vouchesWhileBlockedOrLapsed() public {
        subscriptions.setBlocked(true);
        subscriptions.set(false, 0.01 ether);

        assertEq(signIn(vault, websiteBody(), ownerPk), MAGIC_VALUE);
    }

    function test_vouchesForAContractOwnersApproval() public {
        (address walletSigner, uint256 walletSignerPk) = makeAddrAndKey("walletSigner");
        MockOwnerWallet wallet = new MockOwnerWallet(walletSigner);
        transferVault(address(wallet));

        assertEq(signIn(vault, websiteBody(), walletSignerPk), MAGIC_VALUE);
        expectSignInRevert(ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), ownerPk);
    }

    function testFuzz_vouchesForAnyBodyTheOwnerApproved(bytes memory body, uint32 validFor) public {
        deadline = block.timestamp + validFor;
        bytes32 digest = personalSignDigest(fullMessage(vault, string(body)));

        assertEq(
            vault.isValidSignature(digest, envelope(vault, string(body), deadline, ownerPk)),
            MAGIC_VALUE
        );
    }

    /*//////////////////////////////////////////////////////////////
                                SIGNERS
    //////////////////////////////////////////////////////////////*/

    function test_rejectsTheKeepersApproval() public {
        expectSignInRevert(ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), keeperPk);
    }

    function test_rejectsAStrangersApproval() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        expectSignInRevert(
            ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), strangerPk
        );
    }

    function test_rejectsARejectingContractOwner() public {
        (address walletSigner,) = makeAddrAndKey("walletSigner");
        transferVault(address(new MockOwnerWallet(walletSigner)));

        expectSignInRevert(ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), ownerPk);
    }

    /// @dev The approval follows `owner()`: a pending owner cannot sign in yet, and a previous owner
    ///      can no longer.
    function test_followsOwnershipTransfers() public {
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        expectSignInRevert(
            ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), newOwnerPk
        );
        assertEq(signIn(vault, websiteBody(), ownerPk), MAGIC_VALUE);

        vm.prank(newOwner);
        vault.acceptOwnership();

        assertEq(signIn(vault, websiteBody(), newOwnerPk), MAGIC_VALUE);
        expectSignInRevert(ListoorVault.UnauthorizedSigner.selector, vault, websiteBody(), ownerPk);
    }

    /*//////////////////////////////////////////////////////////////
                                BINDING
    //////////////////////////////////////////////////////////////*/

    function test_rejectsADigestOfAnotherMessage() public {
        bytes32 digest = personalSignDigest(fullMessage(vault, sdkBody()));
        bytes memory signature = envelope(vault, websiteBody(), deadline, ownerPk);

        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        vault.isValidSignature(digest, signature);
    }

    /// @dev The vault writes the opening lines itself, so a message for another site or account,
    ///      or this vault's address in another case, never matches the digest.
    function test_rejectsSignInsForAnotherSiteOrAccount() public {
        string[3] memory messages = [
            string.concat(
                "evil.io wants you to sign in with your Ethereum account:\n",
                Strings.toChecksumHexString(address(vault)),
                "\n",
                websiteBody()
            ),
            string.concat(
                "opensea.io wants you to sign in with your Ethereum account:\n",
                Strings.toChecksumHexString(stranger),
                "\n",
                websiteBody()
            ),
            string.concat(
                "opensea.io wants you to sign in with your Ethereum account:\n",
                Strings.toHexString(address(vault)),
                "\n",
                websiteBody()
            )
        ];
        bytes memory signature = envelope(vault, websiteBody(), deadline, ownerPk);

        for (uint256 i; i < messages.length; ++i) {
            vm.expectRevert(ListoorVault.DigestMismatch.selector);
            vault.isValidSignature(personalSignDigest(messages[i]), signature);
        }
    }

    function test_rejectsAnApprovalForAnotherVault() public {
        ListoorVault other =
            new ListoorVault(address(seaport), conduit, owner, keeper, address(subscriptions));
        bytes memory body = bytes(websiteBody());
        bytes memory signature = abi.encode(
            vault.OPENSEA_LOGIN_TAG(),
            body,
            deadline,
            sign(ownerPk, approvalHash(other, fullMessage(vault, websiteBody()), deadline))
        );

        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vault.isValidSignature(personalSignDigest(fullMessage(vault, websiteBody())), signature);
    }

    function test_rejectsAnApprovalFromAnotherChain() public {
        bytes32 digest = personalSignDigest(fullMessage(vault, websiteBody()));
        bytes memory signature = envelope(vault, websiteBody(), deadline, ownerPk);

        vm.chainId(block.chainid + 1);
        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vault.isValidSignature(digest, signature);
    }

    function test_rejectsAnApprovalWithAnotherDeadline() public {
        bytes memory signature = abi.encode(
            vault.OPENSEA_LOGIN_TAG(),
            bytes(websiteBody()),
            deadline + 1,
            sign(ownerPk, approvalHash(vault, fullMessage(vault, websiteBody()), deadline))
        );

        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vault.isValidSignature(personalSignDigest(fullMessage(vault, websiteBody())), signature);
    }

    function testFuzz_rejectsAnyOtherDigest(bytes32 digest) public {
        vm.assume(digest != personalSignDigest(fullMessage(vault, websiteBody())));
        bytes memory signature = envelope(vault, websiteBody(), deadline, ownerPk);

        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        vault.isValidSignature(digest, signature);
    }

    function test_rejectsAMalformedEnvelope() public {
        bytes memory signature = abi.encodePacked(vault.OPENSEA_LOGIN_TAG(), bytes32(uint256(1)));

        vm.expectRevert();
        vault.isValidSignature(personalSignDigest(fullMessage(vault, websiteBody())), signature);
    }

    /*//////////////////////////////////////////////////////////////
                       SEPARATION FROM ORDER SIGNING
    //////////////////////////////////////////////////////////////*/

    /// @dev With one key as owner and keeper, a sign-in approval still cannot pass as an order, nor
    ///      an order signature as a sign-in approval.
    function test_signInsAndOrdersStaySeparateUnderOneKey() public {
        ListoorVault shared =
            new ListoorVault(address(seaport), conduit, owner, owner, address(subscriptions));
        vm.startPrank(owner);
        shared.setPaymentTokenAllowed(shared.NATIVE_TOKEN(), true);
        shared.setListingFloor(address(nft), FLOOR);
        vm.stopPrank();
        ListoorVault original = vault;
        vault = shared;

        bytes32 orderDigest = digestOf(listing(FLOOR));
        assertEq(
            shared.isValidSignature(orderDigest, payloadFor(listing(FLOOR), ownerPk)), MAGIC_VALUE
        );

        bytes memory signInEnvelope = envelope(shared, websiteBody(), deadline, ownerPk);
        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        shared.isValidSignature(orderDigest, signInEnvelope);

        bytes memory orderSignatureAsApproval = abi.encode(
            shared.OPENSEA_LOGIN_TAG(),
            bytes(websiteBody()),
            deadline,
            signatureFor(listing(FLOOR), ownerPk)
        );
        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        shared.isValidSignature(
            personalSignDigest(fullMessage(shared, websiteBody())), orderSignatureAsApproval
        );

        vault = original;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Everything after the address line of the message opensea.io signs in with.
    function websiteBody() internal pure returns (string memory) {
        return bodyWithUri("https://opensea.io/");
    }

    function sdkBody() internal pure returns (string memory) {
        return bodyWithUri("https://opensea.io");
    }

    function bodyWithUri(string memory uri) internal pure returns (string memory) {
        return string.concat(
            "\n",
            STATEMENT,
            "\n\nURI: ",
            uri,
            "\nVersion: 1\nChain ID: 1\nNonce: b8q4fb9s10at15eho2ksi2e774\nIssued At: 2026-11-01T15:20:19.039Z"
        );
    }

    function fullMessage(ListoorVault account, string memory body)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "opensea.io wants you to sign in with your Ethereum account:\n",
            Strings.toChecksumHexString(address(account)),
            "\n",
            body
        );
    }

    /// @dev EIP-191 `personal_sign` digest, spelled out rather than taken from the library the vault
    ///      uses.
    function personalSignDigest(string memory message) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n", vm.toString(bytes(message).length), message
            )
        );
    }

    function approvalHash(ListoorVault account, string memory message, uint256 deadline_)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Seavault"),
                keccak256("1"),
                block.chainid,
                address(account)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("OpenSeaLogin(string message,uint256 deadline)"),
                keccak256(bytes(message)),
                deadline_
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    function envelope(ListoorVault account, string memory body, uint256 deadline_, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            account.OPENSEA_LOGIN_TAG(),
            bytes(body),
            deadline_,
            sign(pk, approvalHash(account, fullMessage(account, body), deadline_))
        );
    }

    function signIn(ListoorVault account, string memory body, uint256 pk)
        internal
        view
        returns (bytes4)
    {
        return account.isValidSignature(
            personalSignDigest(fullMessage(account, body)), envelope(account, body, deadline, pk)
        );
    }

    function expectSignInRevert(
        bytes4 selector,
        ListoorVault account,
        string memory body,
        uint256 pk
    ) internal {
        bytes32 digest = personalSignDigest(fullMessage(account, body));
        bytes memory signature = envelope(account, body, deadline, pk);
        vm.expectRevert(selector);
        account.isValidSignature(digest, signature);
    }

    function transferVault(address newOwner) internal {
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
    }
}
