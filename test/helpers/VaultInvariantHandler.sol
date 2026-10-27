// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {ItemType, OrderType, Side} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../../src/ListoorVaultFactory.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {SeaportOrderHash} from "../../src/libraries/SeaportOrderHash.sol";
import {MockERC1155, MockERC721} from "../mocks/TokenMocks.sol";

contract InvariantOwner is ERC1155Holder {
    receive() external payable {}
}

/// @dev A hostile seller accepts its own orders and attempts a vault withdrawal during settlement.
contract InvariantTaker is ERC1155Holder, IERC1271 {
    ListoorVault private immutable vault;
    uint256 public callbackAttempts;
    bool public stoleDuringCallback;

    constructor(ListoorVault vault_) {
        vault = vault_;
    }

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        _attack();
        return this.onERC1155Received.selector;
    }

    receive() external payable {
        _attack();
    }

    function _attack() private {
        ++callbackAttempts;
        (bool success,) =
            address(vault).call(abi.encodeCall(ListoorVault.withdrawETH, (address(this), 1)));
        stoleDuringCallback = stoleDuringCallback || success;
    }
}

/// @notice Drives real Seaport settlement with a malicious keeper and taker, plus owner policy changes.
/// @dev Every test NFT unit has a fixed accounting value of 1 ETH. Owner actions keep effective
///      listing floors >= 1 ETH and ceilings <= 1 ETH, including policies cached by Seaport. The
///      independent portfolio oracle can therefore detect economic loss without implementing
///      Seaport's pricing, rounding or policy validation a second time. Its minimum advances after
///      every action, so trading profits cannot hide a later loss. This is a test valuation,
///      not an assertion about market prices. Only the handler's selectors are fuzz targets.
contract VaultInvariantHandler is Test {
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 public constant UNIT = 1 ether;
    uint256 public constant EDITION_ID = 7;
    uint256 public constant NFT_COUNT = 8;
    uint256 public constant TOTAL_EDITIONS = 160;
    uint256 public constant INITIAL_EQUITY = 164 ether;
    uint256 private constant INITIAL_CASH = 1000 ether;
    uint256 private constant MAX_ORDERS = 32;

    ConsiderationInterface public immutable seaport;
    address public immutable conduit;
    bytes32 private immutable conduitKey;
    ListoorVaultFactory public immutable factory;
    ListoorVault public immutable vault;
    MockERC721 public immutable nft;
    MockERC1155 public immutable edition;
    InvariantTaker public immutable taker;
    address[2] public owners;

    uint256 public deposits;
    uint256 public minimumEquity = INITIAL_EQUITY;
    uint256 public expectedNativeAllowance = 32 ether;
    uint256 public expectedWethAllowance = 32 ether;
    uint256 public generation;
    uint256 public successfulFills;
    uint256 public successfulBuys;
    uint256 public successfulMatches;
    uint256 public successfulValidations;
    uint256 public rejectedAttacks;

    uint256 private ownerIndex;
    uint256 private keeperIndex;
    uint256 private salt;

    struct PostedOrder {
        bytes encodedOrder;
        uint256 generation;
        bool authentic;
        bool cancelled;
    }

    PostedOrder[] private orders;

    modifier preservesPortfolio() {
        _;
        uint256 equity = _portfolioEquity();
        assertGe(equity, minimumEquity, "keeper/taker extracted portfolio value");
        minimumEquity = equity;
    }

    constructor(ConsiderationInterface seaport_, address conduit_, bytes32 conduitKey_) {
        seaport = seaport_;
        conduit = conduit_;
        conduitKey = conduitKey_;
        owners[0] = address(new InvariantOwner());
        owners[1] = address(new InvariantOwner());
        nft = new MockERC721();
        edition = new MockERC1155();
        factory = new ListoorVaultFactory(address(seaport_), conduit_, address(this));
        factory.setTrialPeriod(1 hours);
        vm.prank(owners[0]);
        vault = factory.createVault(keccak256("invariants"), _keeper());
        taker = new InvariantTaker(vault);

        vm.startPrank(owners[0]);
        vault.setPaymentTokenAllowed(address(0), true);
        vault.setPaymentTokenAllowed(WETH, true);
        vault.setListingFloor(address(nft), UNIT);
        vault.setListingFloor(address(edition), UNIT);
        vault.setOfferCeiling(address(nft), UNIT);
        vault.setOfferCeiling(address(edition), UNIT);
        vault.setConduitApprovalForAll(address(nft), true);
        vault.setConduitApprovalForAll(address(edition), true);
        vault.setConduitAllowance(WETH, expectedWethAllowance);
        vault.setNativeBuyAllowance(expectedNativeAllowance);
        vm.stopPrank();

        vm.startPrank(address(taker));
        nft.setApprovalForAll(address(seaport_), true);
        edition.setApprovalForAll(address(seaport_), true);
        IERC20(WETH).approve(address(seaport_), type(uint256).max);
        vm.stopPrank();

        // Fund once, through real WETH deposits. Fuzz actions never mint cash or NFTs.
        vm.deal(address(this), INITIAL_CASH);
        _send(address(vault), 64 ether);
        IWETH(WETH).deposit{value: 192 ether}();
        assertTrue(IERC20(WETH).transfer(address(vault), 64 ether));
        assertTrue(IERC20(WETH).transfer(address(taker), 128 ether));
        _send(address(taker), 128 ether);
        for (uint256 i; i < NFT_COUNT; ++i) {
            nft.mint(i < 4 ? address(vault) : address(taker), i);
        }
        edition.mint(address(vault), EDITION_ID, 32);
        edition.mint(address(taker), EDITION_ID, 128);
    }

    /// @dev Attack modes: wrong signer, redirected proceeds/NFTs, tampered signed components,
    ///      excessive fees, declining/rising quantities, and ordinary fees. Bit 4 selects WETH
    ///      listings; bit 5 selects collection criteria on bids; bits 6/7 vary payment amounts.
    function postOrder(
        bool bid,
        bool erc721,
        uint256 quantitySeed,
        uint256 price,
        uint256 attackSeed
    ) external preservesPortfolio returns (uint256 index) {
        uint256 units = erc721 ? 1 : 2 ** (quantitySeed % 4);
        price = bound(price, 0, 2 * UNIT) * units;
        OrderComponents memory components = _components(bid, erc721, quantitySeed, units, price);
        uint256 mode = attackSeed % 8;
        if (!bid && attackSeed & 16 != 0) components.consideration[0].token = WETH;
        if (!bid && attackSeed & 16 != 0) components.consideration[0].itemType = ItemType.ERC20;
        if (bid && attackSeed & 32 != 0) {
            components.consideration[0].itemType =
                erc721 ? ItemType.ERC721_WITH_CRITERIA : ItemType.ERC1155_WITH_CRITERIA;
            components.consideration[0].identifierOrCriteria = 0;
        }
        if (mode == 2) components.consideration[0].recipient = payable(address(taker));
        if (!erc721 && (mode == 5 || mode == 6)) {
            if (bid) {
                components.consideration[0].startAmount = mode == 5 ? units : 1;
                components.consideration[0].endAmount = mode == 5 ? 1 : units;
            } else {
                components.offer[0].startAmount = mode == 5 ? units : 1;
                components.offer[0].endAmount = mode == 5 ? 1 : units;
            }
        }
        if (attackSeed & 64 != 0) {
            uint256 endPrice = attackSeed & 128 == 0 ? price / 2 : price * 2;
            if (bid) components.offer[0].endAmount = endPrice;
            else components.consideration[0].endAmount = endPrice;
        }
        if (mode == 4 || mode == 7) {
            ConsiderationItem[] memory withFee = new ConsiderationItem[](2);
            withFee[0] = components.consideration[0];
            withFee[1] = _payment(
                bid ? WETH : components.consideration[0].token,
                mode == 4 ? price : price / 20,
                address(taker)
            );
            components.consideration = withFee;
        }

        Order memory order =
            _signed(components, mode == 1 ? _key(keeperIndex + 1) : _key(keeperIndex));
        if (mode == 3) order.parameters.consideration[0].recipient = payable(address(taker));
        index = orders.length < MAX_ORDERS ? orders.length : quantitySeed % MAX_ORDERS;
        if (index == orders.length) orders.push();
        PostedOrder storage posted = orders[index];
        posted.encodedOrder = abi.encode(order);
        posted.generation = generation;
        posted.authentic = mode != 1 && mode != 3;
        posted.cancelled = false;
    }

    function validateOrder(uint256 seed) external preservesPortfolio returns (bool success) {
        if (orders.length == 0) return false;
        PostedOrder storage posted = orders[seed % orders.length];
        Order[] memory toValidate = new Order[](1);
        toValidate[0] = abi.decode(posted.encodedOrder, (Order));
        (success,) = _invoke(
            address(taker), address(seaport), abi.encodeCall(seaport.validate, (toValidate)), 0
        );
        if (success) {
            _assertLive(posted);
            ++successfulValidations;
        }
    }

    function fulfillOrder(uint256 seed, uint256 fractionSeed)
        external
        preservesPortfolio
        returns (bool success)
    {
        if (orders.length == 0) return false;
        PostedOrder storage posted = orders[seed % orders.length];
        Order memory order = abi.decode(posted.encodedOrder, (Order));
        uint120 denominator = uint120(2 ** (fractionSeed % 3));
        AdvancedOrder memory advanced =
            AdvancedOrder(order.parameters, 1, denominator, order.signature, "");
        uint256 value;
        for (uint256 i; i < order.parameters.consideration.length; ++i) {
            ConsiderationItem memory item = order.parameters.consideration[i];
            if (item.itemType == ItemType.NATIVE) {
                value += item.startAmount > item.endAmount ? item.startAmount : item.endAmount;
            }
        }
        CriteriaResolver[] memory criteria = new CriteriaResolver[](0);
        ItemType received = order.parameters.consideration[0].itemType;
        if (received == ItemType.ERC721_WITH_CRITERIA || received == ItemType.ERC1155_WITH_CRITERIA)
        {
            criteria = new CriteriaResolver[](1);
            criteria[0] = CriteriaResolver(
                0,
                Side.CONSIDERATION,
                0,
                received == ItemType.ERC721_WITH_CRITERIA ? 4 : EDITION_ID,
                new bytes32[](0)
            );
        }
        uint256 beforeWeth = IERC20(WETH).balanceOf(address(vault));
        (success,) = _invoke(
            address(taker),
            address(seaport),
            abi.encodeCall(
                seaport.fulfillAdvancedOrder, (advanced, criteria, bytes32(0), address(taker))
            ),
            value
        );
        if (success) {
            _assertLive(posted);
            uint256 afterWeth = IERC20(WETH).balanceOf(address(vault));
            if (afterWeth < beforeWeth) expectedWethAllowance -= beforeWeth - afterWeth;
            ++successfulFills;
        }
    }

    function cancelOrder(uint256 seed) external preservesPortfolio {
        if (orders.length == 0) return;
        PostedOrder storage posted = orders[seed % orders.length];
        OrderComponents[] memory toCancel = new OrderComponents[](1);
        Order memory order = abi.decode(posted.encodedOrder, (Order));
        (toCancel[0],) = abi.decode(order.signature, (OrderComponents, bytes));
        vm.prank(_keeper());
        assertTrue(vault.cancelOrders(toCancel));
        posted.cancelled = true;
    }

    function revokeOrders(uint256 seed) external preservesPortfolio {
        vm.startPrank(owners[ownerIndex]);
        if (seed % 4 == 3) {
            vault.incrementCounter();
        } else {
            keeperIndex = seed % 3;
            vault.setKeeper(_keeper());
        }
        vm.stopPrank();
        ++generation;
    }

    function buy(bool erc721, bool useWeth, uint256 quantitySeed, uint256 price, uint256 feeSeed)
        external
        preservesPortfolio
        returns (bool success)
    {
        uint256 units = erc721 ? 1 : 2 ** (quantitySeed % 4);
        price = bound(price, 0, 2 * UNIT) * units;
        uint256 fee = bound(feeSeed / 3, 0, UNIT / 4) * units;
        uint120 denominator = uint120(2 ** (feeSeed % 3));
        OrderComponents memory components = _components(false, erc721, quantitySeed, units, price);
        components.offerer = address(taker);
        components.conduitKey = bytes32(0);
        if (erc721) components.offer[0].identifierOrCriteria = 4 + quantitySeed % 4;
        components.consideration = new ConsiderationItem[](fee == 0 ? 1 : 2);
        components.consideration[0] = _payment(useWeth ? WETH : address(0), price, address(taker));
        if (fee != 0) {
            components.consideration[1] = _payment(useWeth ? WETH : address(0), fee, address(taker));
        }
        AdvancedOrder memory order = AdvancedOrder(_parameters(components), 1, denominator, "", "");
        uint256 beforeEditions = edition.balanceOf(owners[ownerIndex], EDITION_ID);
        (success,) =
            _invoke(_keeper(), address(vault), abi.encodeCall(vault.buy, (order, conduitKey)), 0);
        if (success) {
            uint256 value = (price + fee + denominator - 1) / denominator;
            if (useWeth) expectedWethAllowance -= value;
            else expectedNativeAllowance -= value;
            if (erc721) {
                assertEq(nft.ownerOf(components.offer[0].identifierOrCriteria), owners[ownerIndex]);
            } else {
                assertEq(
                    edition.balanceOf(owners[ownerIndex], EDITION_ID) - beforeEditions,
                    units / denominator
                );
            }
            ++successfulBuys;
        }
    }

    /// @dev Match the vault's own bid and listing. Excess offered WETH is claimable by the taker,
    ///      so an unsafe floor/ceiling gap turns this into a repeatable drain without a new NFT.
    function matchOrders(uint256 quantitySeed, uint256 bidPrice, uint256 salePrice)
        external
        preservesPortfolio
        returns (bool success)
    {
        uint256 units = 2 ** (quantitySeed % 4);
        bidPrice = bound(bidPrice, 0, 2 * UNIT) * units;
        salePrice = bound(salePrice, 0, 2 * UNIT) * units;
        Order[] memory pair = new Order[](2);
        OrderComponents memory sale = _components(false, false, 0, units, salePrice);
        sale.consideration[0] = _payment(WETH, salePrice, address(vault));
        pair[0] = _signed(sale, _key(keeperIndex));
        pair[1] = _signed(_components(true, false, 0, units, bidPrice), _key(keeperIndex));
        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        fulfillments[0] = _fulfillment(0, 1);
        fulfillments[1] = _fulfillment(1, 0);
        (success,) = _invoke(
            address(taker),
            address(seaport),
            abi.encodeCall(seaport.matchOrders, (pair, fulfillments)),
            0
        );
        if (success) {
            expectedWethAllowance -= bidPrice;
            ++successfulMatches;
        }
    }

    function configurePolicy(uint256 seed) external preservesPortfolio {
        uint256 ceiling = (seed % 5) * UNIT / 4;
        // A ceiling below UNIT must leave every raw floor at least UNIT for the fixed valuation.
        uint256 minimum = ceiling == UNIT ? UNIT / 4 : UNIT;
        uint256 floor = bound(seed >> 8, minimum, 2 * UNIT);
        uint256 overrideFloor = seed & 32 == 0 ? 0 : floor;
        vm.startPrank(owners[ownerIndex]);
        vault.setOfferCeiling(address(nft), ceiling);
        vault.setOfferCeiling(address(edition), ceiling);
        vault.setListingFloor(address(nft), floor);
        vault.setListingFloor(address(edition), floor);
        vault.setTokenListingFloor(address(nft), seed % NFT_COUNT, overrideFloor);
        // Clear old per-token overrides when lowering the ceiling below the valuation.
        if (ceiling < UNIT) {
            for (uint256 i; i < NFT_COUNT; ++i) {
                vault.setTokenListingFloor(address(nft), i, 0);
            }
        }
        vault.setPaymentTokenAllowed(WETH, seed & 64 == 0);
        vault.setPaymentTokenAllowed(address(0), seed & 128 == 0);
        vault.setMaxFeeBps(bound(seed >> 16, 0, 1000));
        vm.stopPrank();
    }

    function setBudgets(uint256 nativeAmount, uint256 wethAmount) external preservesPortfolio {
        expectedNativeAllowance = bound(nativeAmount, 0, 32 ether);
        expectedWethAllowance = bound(wethAmount, 0, 32 ether);
        vm.startPrank(owners[ownerIndex]);
        vault.setNativeBuyAllowance(expectedNativeAllowance);
        vault.setConduitAllowance(WETH, expectedWethAllowance);
        vm.stopPrank();
    }

    function wrap(uint256 amount, bool unwrap) external preservesPortfolio returns (bool success) {
        amount = bound(
            amount, 0, unwrap ? IERC20(WETH).balanceOf(address(vault)) : address(vault).balance
        );
        (success,) = _invoke(
            _keeper(),
            address(vault),
            unwrap
                ? abi.encodeCall(vault.unwrapWETH, (WETH, amount))
                : abi.encodeCall(vault.wrapETH, (WETH, amount)),
            0
        );
    }

    function withdraw(uint256 amount, bool weth, bool automatic)
        external
        preservesPortfolio
        returns (bool success)
    {
        amount = bound(
            amount, 0, weth ? IERC20(WETH).balanceOf(address(vault)) : address(vault).balance
        );
        bytes memory data = automatic
            ? (weth
                    ? abi.encodeCall(vault.autoWithdrawERC20, (WETH, amount))
                    : abi.encodeCall(vault.autoWithdrawETH, (amount)))
            : (weth
                    ? abi.encodeCall(vault.withdrawERC20, (WETH, owners[ownerIndex], amount))
                    : abi.encodeCall(vault.withdrawETH, (owners[ownerIndex], amount)));
        uint256 beforeCash = _cash(owners[ownerIndex]);
        (success,) = _invoke(automatic ? _keeper() : owners[ownerIndex], address(vault), data, 0);
        if (success) {
            assertEq(
                _cash(owners[ownerIndex]) - beforeCash, amount, "withdrawal missed current owner"
            );
        }
    }

    function setAutoWithdraw(bool enabled) external preservesPortfolio {
        _invoke(
            owners[ownerIndex],
            address(vault),
            abi.encodeCall(vault.setAutoWithdrawEnabled, (enabled)),
            0
        );
    }

    function transferOwnership() external preservesPortfolio {
        vm.prank(owners[ownerIndex]);
        vault.transferOwnership(owners[1 - ownerIndex]);
        ownerIndex = 1 - ownerIndex;
        vm.prank(owners[ownerIndex]);
        vault.acceptOwnership();
        assertFalse(
            vault.autoWithdrawEnabled(), "ownership transfer retained keeper withdrawal opt-in"
        );
    }

    function setAccess(bool blocked, bool subscribed) external preservesPortfolio {
        factory.setBlocked(address(vault), blocked);
        factory.setSubscription(address(this), subscribed ? 0 : UNIT / 100);
    }

    function advanceTime(uint256 seconds_) external preservesPortfolio {
        vm.warp(block.timestamp + bound(seconds_, 0, 2 hours));
    }

    function deposit(uint256 amount) external preservesPortfolio {
        amount = bound(amount, 0, address(this).balance < 4 ether ? address(this).balance : 4 ether);
        deposits += amount;
        minimumEquity += amount;
        _send(address(vault), amount);
    }

    function attack(uint256 seed, bool asKeeper) external preservesPortfolio {
        bytes memory data;
        uint256 action = seed % 18;
        if (action == 0) {
            data = abi.encodeCall(vault.withdrawETH, (address(taker), 1));
        } else if (action == 1) {
            data = abi.encodeCall(vault.withdrawERC20, (WETH, address(taker), 1));
        } else if (action == 2) {
            data = abi.encodeCall(
                vault.withdrawERC721, (address(nft), address(taker), seed % NFT_COUNT)
            );
        } else if (action == 3) {
            data = abi.encodeCall(
                vault.withdrawERC1155, (address(edition), address(taker), EDITION_ID, 1)
            );
        } else if (action == 4) {
            data = abi.encodeCall(vault.setConduitAllowance, (WETH, type(uint256).max));
        } else if (action == 5) {
            data = abi.encodeCall(vault.setConduitApprovalForAll, (address(nft), true));
        } else if (action == 6) {
            data = abi.encodeCall(vault.setListingFloor, (address(nft), 0));
        } else if (action == 7) {
            data = abi.encodeCall(vault.setOfferCeiling, (address(nft), type(uint256).max));
        } else if (action == 8) {
            data = abi.encodeCall(vault.setKeeper, (address(taker)));
        } else if (action == 9) {
            data = abi.encodeCall(vault.transferOwnership, (address(taker)));
        } else if (action == 10) {
            data = abi.encodeCall(vault.setAutoWithdrawEnabled, (true));
        } else if (action == 11) {
            data = abi.encodeCall(vault.renewSubscription, (1, type(uint256).max));
        } else if (action == 12) {
            data = abi.encodeCall(vault.wrapETH, (WETH, 1));
        } else if (action == 13) {
            data = abi.encodeCall(vault.unwrapWETH, (WETH, 1));
        } else if (action == 14) {
            data = abi.encodeCall(vault.autoWithdrawETH, (1));
        } else if (action == 15) {
            data = abi.encodeCall(vault.autoWithdrawERC20, (WETH, 1));
        } else if (action == 16) {
            data = abi.encodeCall(vault.incrementCounter, ());
        } else {
            data = abi.encodeCall(vault.setNativeBuyAllowance, (type(uint256).max));
        }
        address caller =
            asKeeper ? (action < 12 ? _keeper() : vm.addr(_key(keeperIndex + 1))) : address(taker);
        (bool success,) = _invoke(caller, address(vault), data, 0);
        assertFalse(success, "untrusted caller acquired owner authority");
        ++rejectedAttacks;
    }

    function assertPortfolio() public view {
        assertGe(_portfolioEquity(), minimumEquity, "keeper/taker extracted portfolio value");
        assertGe(minimumEquity, INITIAL_EQUITY + deposits, "deposits were not accounted for");
    }

    function _portfolioEquity() private view returns (uint256 equity) {
        equity = _cash(address(vault)) + _cash(owners[0]) + _cash(owners[1]);
        equity += UNIT
            * (edition.balanceOf(address(vault), EDITION_ID)
                + edition.balanceOf(owners[0], EDITION_ID)
                + edition.balanceOf(owners[1], EDITION_ID));
        for (uint256 i; i < NFT_COUNT; ++i) {
            address holder = nft.ownerOf(i);
            if (holder == address(vault) || holder == owners[0] || holder == owners[1]) {
                equity += UNIT;
            }
        }
    }

    function assertConservation() public view {
        assertEq(
            _cash(address(this)) + _cash(address(taker)) + _cash(address(vault)) + _cash(owners[0])
                + _cash(owners[1]),
            INITIAL_CASH,
            "cash left the closed system"
        );
        assertEq(
            edition.balanceOf(address(taker), EDITION_ID)
                + edition.balanceOf(address(vault), EDITION_ID)
                + edition.balanceOf(owners[0], EDITION_ID)
                + edition.balanceOf(owners[1], EDITION_ID),
            TOTAL_EDITIONS,
            "ERC1155 units lost or created"
        );
        for (uint256 i; i < NFT_COUNT; ++i) {
            address holder = nft.ownerOf(i);
            assertTrue(
                holder == address(vault) || holder == address(taker) || holder == owners[0]
                    || holder == owners[1],
                "NFT escaped tracked custody"
            );
        }
    }

    function assertAuthority() public view {
        assertEq(vault.owner(), owners[ownerIndex]);
        assertEq(vault.keeper(), _keeper());
        assertEq(factory.ownedVaultOf(owners[ownerIndex]), address(vault));
        assertEq(factory.ownedVaultOf(owners[1 - ownerIndex]), address(0));
        assertEq(vault.nativeBuyAllowance(), expectedNativeAllowance, "native budget drift");
        assertEq(
            IERC20(WETH).allowance(address(vault), conduit),
            expectedWethAllowance,
            "WETH budget drift"
        );
        assertFalse(taker.stoleDuringCallback(), "settlement callback withdrew vault funds");
    }

    /// @dev Run after each campaign, including blocked and lapsed states, to prove manual exit works.
    function exitToOwner() external {
        vm.startPrank(owners[ownerIndex]);
        vault.withdrawETH(owners[ownerIndex], address(vault).balance);
        vault.withdrawERC20(WETH, owners[ownerIndex], IERC20(WETH).balanceOf(address(vault)));
        vault.withdrawERC1155(
            address(edition),
            owners[ownerIndex],
            EDITION_ID,
            edition.balanceOf(address(vault), EDITION_ID)
        );
        for (uint256 i; i < NFT_COUNT; ++i) {
            if (nft.ownerOf(i) == address(vault)) {
                vault.withdrawERC721(address(nft), owners[ownerIndex], i);
            }
        }
        vm.stopPrank();
        assertEq(_cash(address(vault)), 0);
        assertEq(edition.balanceOf(address(vault), EDITION_ID), 0);
        assertEq(nft.balanceOf(address(vault)), 0);
        assertPortfolio();
        assertConservation();
        assertAuthority();
    }

    function _components(bool bid, bool erc721, uint256 idSeed, uint256 units, uint256 price)
        private
        returns (OrderComponents memory order)
    {
        order.offerer = address(vault);
        order.offer = new OfferItem[](1);
        order.consideration = new ConsiderationItem[](1);
        OfferItem memory item = OfferItem(
            erc721 ? ItemType.ERC721 : ItemType.ERC1155,
            erc721 ? address(nft) : address(edition),
            erc721 ? idSeed % NFT_COUNT : EDITION_ID,
            units,
            units
        );
        if (bid) {
            order.offer[0] = OfferItem(ItemType.ERC20, WETH, 0, price, price);
            order.consideration[0] = ConsiderationItem(
                item.itemType,
                item.token,
                item.identifierOrCriteria,
                units,
                units,
                payable(address(vault))
            );
        } else {
            order.offer[0] = item;
            order.consideration[0] = _payment(address(0), price, address(vault));
        }
        order.orderType = erc721 ? OrderType.FULL_OPEN : OrderType.PARTIAL_OPEN;
        order.startTime = block.timestamp;
        order.endTime = block.timestamp + 1 hours;
        order.salt = ++salt;
        order.conduitKey = conduitKey;
        order.counter = seaport.getCounter(address(vault));
    }

    function _signed(OrderComponents memory components, uint256 key)
        private
        view
        returns (Order memory)
    {
        (, bytes32 separator,) = seaport.information();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, SeaportOrderHash.digest(separator, components));
        return Order(_parameters(components), abi.encode(components, abi.encodePacked(r, s, v)));
    }

    function _parameters(OrderComponents memory c) private pure returns (OrderParameters memory) {
        return OrderParameters(
            c.offerer,
            c.zone,
            c.offer,
            c.consideration,
            c.orderType,
            c.startTime,
            c.endTime,
            c.zoneHash,
            c.salt,
            c.conduitKey,
            c.consideration.length
        );
    }

    function _payment(address token, uint256 amount, address to)
        private
        pure
        returns (ConsiderationItem memory)
    {
        return ConsiderationItem(
            token == address(0) ? ItemType.NATIVE : ItemType.ERC20,
            token,
            0,
            amount,
            amount,
            payable(to)
        );
    }

    function _fulfillment(uint256 offerIndex, uint256 considerationIndex)
        private
        pure
        returns (Fulfillment memory)
    {
        FulfillmentComponent[] memory offered = new FulfillmentComponent[](1);
        FulfillmentComponent[] memory received = new FulfillmentComponent[](1);
        offered[0] = FulfillmentComponent(offerIndex, 0);
        received[0] = FulfillmentComponent(considerationIndex, 0);
        return Fulfillment(offered, received);
    }

    function _assertLive(PostedOrder storage posted) private view {
        assertTrue(posted.authentic, "forged or tampered order accepted");
        assertFalse(posted.cancelled, "cancelled order accepted");
        assertEq(posted.generation, generation, "revoked order accepted");
    }

    function _key(uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("vault invariant keeper", index % 3)));
    }

    function _keeper() private view returns (address) {
        return vm.addr(_key(keeperIndex));
    }

    function _cash(address account) private view returns (uint256) {
        return account.balance + IERC20(WETH).balanceOf(account);
    }

    function _invoke(address from, address target, bytes memory data, uint256 value)
        private
        returns (bool success, bytes memory result)
    {
        vm.prank(from);
        return target.call{value: value}(data);
    }

    function _send(address to, uint256 amount) private {
        (bool success,) = to.call{value: amount}("");
        assertTrue(success);
    }

    receive() external payable {}
}
