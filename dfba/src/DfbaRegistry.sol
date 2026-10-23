// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract DualFlowRegistry {
    enum DualFlowPermissions {
        // Default
        MarketTaker,
        // able to post maker orders
        MarketMaker,
        // able to assign market makers
        MarketMakerAdmin,
        // unable to submit any orders.
        BlackListed
    }
    mapping(address => DualFlowPermissions) public Permissions;
    address public token;

    constructor(address admin, address _token) {
        Permissions[admin] = DualFlowPermissions.MarketMakerAdmin;
        token = _token;
    }

    function isMaker(address userAddress) public view returns (bool) {
        if (Permissions[userAddress] == DualFlowPermissions.MarketMaker) {
            return true;
        } else {
            return false;
        }
    }

    function blackList(address userAddress) public {
        require(
            Permissions[msg.sender] == DualFlowPermissions.MarketMakerAdmin,
            "only MarketMakerAdmin may blackliste users"
        );
        Permissions[userAddress] = DualFlowPermissions.BlackListed;
    }

    modifier notBlacklisted() {
        require(Permissions[msg.sender] != DualFlowPermissions.BlackListed, "blacklisted address");
        _;
    }

    function assignMaker(address marketMaker) public {
        require(Permissions[msg.sender] == DualFlowPermissions.MarketMakerAdmin, "you are not an MM admin");
        Permissions[marketMaker] = DualFlowPermissions.MarketMaker;
    }

    function assignMakerAdmin(address marketMakerAdmin) public {
        require(Permissions[msg.sender] == DualFlowPermissions.MarketMakerAdmin, "you are not an MM admin");
        Permissions[marketMakerAdmin] = DualFlowPermissions.MarketMakerAdmin;
    }
}
