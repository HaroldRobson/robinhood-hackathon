// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {DualFlowRegistry} from "./DfbaRegistry.sol";

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

contract DualFlowAuction is DualFlowRegistry {
    modifier nonReentrant() {
        require(!locked, "reentrancy guard");
        locked = true;
        _;
        locked = false;
    }
    bool transient locked;

    struct Order {
        uint256 asset_a_size;
        uint256 asset_b_size;
        bool is_ioc;
        bool is_fok;
        bool is_bid;
        address user;
        uint256 previous;
        uint256 next;
    }

    address public feeRecipient;
    address public owner;
    address public assetA;
    address public assetB;
    // in 1e-6
    uint64 public feeMaker;
    uint64 public feeTaker;
    // in 1e-6
    uint64 public feeShareSettlementTriggerer;
    // bid = buying asset_a
    uint256 public bestMakerBid;
    uint256 public bestMakerAsk;
    uint256 public bestTakerBid;
    uint256 public bestTakerAsk;
    mapping(uint256 => Order) public Orders;

    enum OrderCancellationReason {
        WasIoc,
        UserCancelled
    }

    constructor(address _feeRecipient, uint8 _feeMaker, uint8 _feeTaker, uint8 _feeShareSettlementTriggerer) {
        feeRecipient = _feeRecipient;
        feeMaker = _feeMaker;
        feeTaker = _feeTaker;
        feeShareSettlementTriggerer = _feeShareSettlementTriggerer;
        owner = msg.sender;
    }

    event orderCancelled(
        uint256 order_id,
        address user,
        uint256 asset_a_size,
        uint256 asset_b_size,
        OrderCancellationReason cancellation_reason
    );

    event orderPlaced(
        uint256 order_id,
        address user,
        uint256 asset_a_size,
        uint256 asset_b_size,
        bool is_ioc,
        bool is_fok,
        bool is_bid
    );

    event orderModified(
        uint256 order_id,
        address user,
        uint256 asset_a_size,
        uint256 asset_b_size,
        bool is_ioc,
        bool is_fok,
        bool is_bid
    );

    event fillHappened(address maker, address taker, uint256 asset_a_size, uint256 asset_b_size, bool is_buyer_maker);

    function placeOrder(
        bool is_maker,
        bool is_ioc,
        bool is_fok,
        bool is_bid,
        uint256 asset_a_size,
        uint256 asset_b_size
    ) public nonReentrant notBlackListed returns (uint256) {
        bool is_taker = !is_maker;
        bool is_ask = !is_bid;
        uint256 previous;
        uint256 next;

        if (is_bid) {
            require(
                IERC20(assetB).transferFrom(msg.sender, address(this), asset_b_size), "insufficient funds or allowance"
            );
        } else {
            require(
                IERC20(assetA).transferFrom(msg.sender, address(this), asset_a_size), "insufficient funds or allowance"
            );
        }

        if (is_bid && is_maker) {
            next = bestMakerBid;
            while (Orders[next].asset_b_size * asset_a_size > asset_b_size * Orders[next].asset_b_size) {
                previous = next;
                next = Orders[next].next;
            }
        } else if (is_bid && is_taker) {
            next = bestTakerBid;
            while (Orders[next].asset_b_size * asset_a_size > asset_b_size * Orders[next].asset_b_size) {
                previous = next;
                next = Orders[next].next;
            }
        } else if (is_ask && is_maker) {
            next = bestMakerAsk;
            while (Orders[next].asset_b_size * asset_a_size < asset_b_size * Orders[next].asset_b_size) {
                previous = next;
                next = Orders[next].next;
            }
        } else if (is_ask && is_maker) {
            next = bestTakerAsk;
            while (Orders[next].asset_b_size * asset_a_size < asset_b_size * Orders[next].asset_b_size) {
                previous = next;
                next = Orders[next].next;
            }
        }

        Order memory order;
        order.asset_a_size = asset_a_size;
        order.asset_b_size = asset_b_size;
        order.is_ioc = is_ioc;
        order.is_fok = is_fok;
        order.is_bid = is_bid;
        order.user = msg.sender;
        order.previous = previous;
        order.next = next;

        uint256 current = uint256(keccak256(abi.encode(order)));
        Orders[current] = order;
        Orders[previous].next = current;
        Orders[next].previous = current;

        if (next == bestMakerBid) bestMakerBid = current;
        if (next == bestTakerBid) bestTakerBid = current;
        if (next == bestMakerAsk) bestMakerAsk = current;
        if (next == bestTakerAsk) bestTakerAsk = current;

        emit orderPlaced(current, msg.sender, asset_a_size, asset_b_size, is_fok, is_ioc, is_bid);
        return current;
    }

    function cancelOrder(uint256 order_id) public nonReentrant notBlackListed {
        require(Orders[order_id].user == msg.sender, "you are not the original sender");
        uint256 previous = Orders[order_id].previous;
        uint256 next = Orders[order_id].next;
        Orders[previous].next = next;
        Orders[next].previous = previous;
        if (Orders[order_id].is_bid) {
            require(IERC20(assetA).transfer(msg.sender, Orders[order_id].asset_a_size), "refund failed");
        } else {
            require(IERC20(assetB).transfer(msg.sender, Orders[order_id].asset_b_size), "refund failed");
        }
        emit orderCancelled(
            order_id,
            msg.sender,
            Orders[order_id].asset_a_size,
            Orders[order_id].asset_b_size,
            OrderCancellationReason.UserCancelled
        );
        // drop Orders[order_id] here?
    }

    // resize_multiple is a 1e18 float for rescaling size
    function modifyOrder(bool is_ioc, bool is_fok, uint256 order_id, uint256 resize_multiple) public {
        require(Orders[order_id].user == msg.sender, "you are not the original sender");
        uint256 original_asset_a_size = Orders[order_id].asset_a_size;
        uint256 original_asset_b_size = Orders[order_id].asset_b_size;
        uint256 newASize = (original_asset_a_size * resize_multiple) / 1e18;
        uint256 newBSize = (original_asset_b_size * resize_multiple) / 1e18;
        Orders[order_id].asset_a_size = newASize;
        Orders[order_id].asset_b_size = newBSize;
        Orders[order_id].is_ioc = is_ioc;
        Orders[order_id].is_fok = is_fok;
        emit orderModified(order_id, user, newASize, newBSize, is_ioc, is_fok, Orders[order_id].is_bid);
    }

    function triggerSettlement(bool is_bid_auction) public {
        if (is_bid_auction) {}
    }

    ///the amount of asset_b required to buy 1 asset_a
    function findSettlementBidPrice() public view returns (uint256) {
        uint256 asset_a_decimals = IERC20(assetA).decimals();
        uint256 asset_b_decimals = IERC20(assetB).decimals();
        // volume is measured in terms of A
        uint256 bidVolumeGeqPrice = 0;
        uint256 askVolumeLeqPrice = 0;

        // firstly we start at the bestMaker
        uint256 currentBid = bestMakerBid;
        uint256 nextBid = Orders[bestMakerBid].next;
        uint256 currentAsk = bestTakerAsk;
        uint256 nextAsk = Orders[bestAsk].next;
        uint256 matchedVolume = 0;
        // find the worst ask still lower than the currentBid
        //while Orders[currentAsk].asset_a_size *

        // starst going through them all adding to volume until wei have reached the worst ask.
    }

    /// the amount of asset_b that would be recieved from selling 1 asset_a
    function findSettlementAskPrice() public view returns (uint256) {}
}
