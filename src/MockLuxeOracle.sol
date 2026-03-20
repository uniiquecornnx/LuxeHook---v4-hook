// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockLuxeOracle
/// @notice A mock oracle for local testing. In production, replace with a
///         Chainlink Functions or a custom off-chain price feed for diamond valuations.
/// @dev Diamond pricing in production would source from:
///      - GIA (Gemological Institute of America) certified appraisals
///      - IDEX (International Diamond Exchange) spot prices
///      - Rappaport diamond price sheets
contract MockLuxeOracle is Ownable {
    struct PriceData {
        uint256 price;       // USD price, 18 decimals
        uint256 updatedAt;   // Last update timestamp
        bool certified;      // Whether the token is certified/verified
    }

    mapping(address => PriceData) public priceData;

    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event CertificationSet(address indexed token, bool certified);

    constructor() Ownable(msg.sender) {}

    // ─── Owner Functions ─────────────────────────────────────────────────────

    /// @notice Set the price and certification for a diamond token
    function setPrice(address token, uint256 price, bool _certified) external onlyOwner {
        priceData[token] = PriceData({
            price: price,
            updatedAt: block.timestamp,
            certified: _certified
        });
        emit PriceUpdated(token, price, block.timestamp);
        emit CertificationSet(token, _certified);
    }

    /// @notice Update just the price (keeps certification)
    function updatePrice(address token, uint256 price) external onlyOwner {
        priceData[token].price = price;
        priceData[token].updatedAt = block.timestamp;
        emit PriceUpdated(token, price, block.timestamp);
    }

    /// @notice Simulate a stale price (for testing staleness checks)
    function setStalePrice(address token, uint256 price, uint256 staleSince) external onlyOwner {
        priceData[token].price = price;
        priceData[token].updatedAt = staleSince;
    }

    /// @notice Set certification status
    function setCertified(address token, bool _certified) external onlyOwner {
        priceData[token].certified = _certified;
        emit CertificationSet(token, _certified);
    }

    // ─── Oracle Interface ─────────────────────────────────────────────────────

    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = priceData[token];
        require(data.updatedAt > 0, "MockLuxeOracle: no price set");
        return (data.price, data.updatedAt);
    }

    function isCertified(address token) external view returns (bool) {
        return priceData[token].certified;
    }
}
