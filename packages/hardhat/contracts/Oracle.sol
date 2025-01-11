// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@redstone-finance/evm-connector/contracts/data-services/MainDemoConsumerBase.sol";
import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";
import "@uma/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";

contract CryptoOracleAggregator is 
    Ownable, 
    Pausable, 
    ReentrancyGuard, 
    MainDemoConsumerBase,
    RrpRequesterV0 
{
    struct OracleConfig {
        address chainlinkFeed;
        bytes32 redstoneFeedId;
        bytes32 api3FeedId;
        address umaFeed;
        uint256 heartbeat;
        uint256 deviation;
        bool isActive;
        mapping(uint8 => bool) sourceActive; // Maps oracle source to active status
    }

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
        uint8 source;      // 1: Chainlink, 2: RedStone, 3: API3, 4: UMA
        bool isOutlier;
    }

    struct AggregatedPrice {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
        uint8 sourcesUsed;
        bool isValid;
    }

    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_PRICE_DEVIATION = 1000; // 10%
    uint256 private constant MIN_CONFIDENCE = 70;
    uint256 private constant MAX_SOURCE_DEVIATION = 500; // 5%
    uint8 private constant MIN_SOURCES = 2;

    // Storage
    mapping(string => OracleConfig) public oracleConfigs;
    mapping(string => AggregatedPrice) public latestAggregatedPrices;
    mapping(string => mapping(uint8 => PriceData)) public sourcePrices;
    mapping(bytes32 => string) public pendingRequests;
    
    // UMA Oracle Interface
    OptimisticOracleV2Interface public umaOracle;
    
    // Events
    event PriceSourceUpdated(
        string indexed asset,
        uint8 source,
        uint256 price,
        uint256 timestamp,
        uint256 confidence
    );
    event AggregatedPriceUpdated(
        string indexed asset,
        uint256 price,
        uint256 confidence,
        uint8 sourcesUsed
    );
    event OracleConfigured(
        string indexed asset,
        address chainlinkFeed,
        bytes32 redstoneFeedId,
        bytes32 api3FeedId,
        address umaFeed
    );
    event PriceOutlierDetected(
        string indexed asset,
        uint8 source,
        uint256 price,
        uint256 aggregatedPrice
    );
    event SourceFailure(
        string indexed asset,
        uint8 source,
        string reason
    );

    // Custom errors
    error InsufficientSources(string asset, uint8 sourcesAvailable, uint8 sourcesRequired);
    error PriceDeviationTooHigh(string asset, uint256 deviation, uint256 maxDeviation);
    error StalePrice(string asset, uint256 timestamp, uint256 maxAge);
    error InvalidConfidence(string asset, uint256 confidence, uint256 minConfidence);
    error SourceUnavailable(string asset, uint8 source);

    constructor(address _airnodeRrp, address _umaOracle) RrpRequesterV0(_airnodeRrp) {
        umaOracle = OptimisticOracleV2Interface(_umaOracle);
    }

    function configureOracle(
        string memory asset,
        address chainlinkFeed,
        bytes32 redstoneFeedId,
        bytes32 api3FeedId,
        address umaFeed,
        uint256 heartbeat,
        uint256 deviation
    ) external onlyOwner {
        require(bytes(asset).length > 0, "Invalid asset");
        require(heartbeat > 0, "Invalid heartbeat");
        require(deviation > 0, "Invalid deviation");

        OracleConfig storage config = oracleConfigs[asset];
        config.chainlinkFeed = chainlinkFeed;
        config.redstoneFeedId = redstoneFeedId;
        config.api3FeedId = api3FeedId;
        config.umaFeed = umaFeed;
        config.heartbeat = heartbeat;
        config.deviation = deviation;
        config.isActive = true;

        // Activate sources based on provided addresses
        config.sourceActive[1] = chainlinkFeed != address(0);
        config.sourceActive[2] = redstoneFeedId != bytes32(0);
        config.sourceActive[3] = api3FeedId != bytes32(0);
        config.sourceActive[4] = umaFeed != address(0);

        emit OracleConfigured(
            asset,
            chainlinkFeed,
            redstoneFeedId,
            api3FeedId,
            umaFeed
        );
    }

    function getLatestPrice(string memory asset) 
        public 
        view 
        returns (
            uint256 price,
            uint256 timestamp,
            uint256 confidence
        ) 
    {
        AggregatedPrice memory aggPrice = latestAggregatedPrices[asset];
        require(aggPrice.isValid, "No valid price available");

        if (block.timestamp - aggPrice.timestamp > oracleConfigs[asset].heartbeat) {
            revert StalePrice(asset, aggPrice.timestamp, oracleConfigs[asset].heartbeat);
        }

        return (aggPrice.price, aggPrice.timestamp, aggPrice.confidence);
    }

    function updatePrices(string memory asset) external nonReentrant whenNotPaused {
        OracleConfig storage config = oracleConfigs[asset];
        require(config.isActive, "Oracle not active");

        uint8 validSources = 0;
        uint256 totalPrice = 0;
        uint256 minPrice = type(uint256).max;
        uint256 maxPrice = 0;

        // Collect prices from all active sources
        if (config.sourceActive[1]) {
            try this.getChainlinkPrice(asset) returns (PriceData memory priceData) {
                if (validatePrice(asset, priceData)) {
                    sourcePrices[asset][1] = priceData;
                    validSources++;
                    totalPrice += priceData.price;
                    minPrice = min(minPrice, priceData.price);
                    maxPrice = max(maxPrice, priceData.price);
                }
            } catch {
                emit SourceFailure(asset, 1, "Chainlink source failed");
            }
        }

        if (config.sourceActive[2]) {
            try this.getRedStonePrice(asset) returns (PriceData memory priceData) {
                if (validatePrice(asset, priceData)) {
                    sourcePrices[asset][2] = priceData;
                    validSources++;
                    totalPrice += priceData.price;
                    minPrice = min(minPrice, priceData.price);
                    maxPrice = max(maxPrice, priceData.price);
                }
            } catch {
                emit SourceFailure(asset, 2, "RedStone source failed");
            }
        }

        if (config.sourceActive[3]) {
            try this.getAPI3Price(asset) returns (PriceData memory priceData) {
                if (validatePrice(asset, priceData)) {
                    sourcePrices[asset][3] = priceData;
                    validSources++;
                    totalPrice += priceData.price;
                    minPrice = min(minPrice, priceData.price);
                    maxPrice = max(maxPrice, priceData.price);
                }
            } catch {
                emit SourceFailure(asset, 3, "API3 source failed");
            }
        }

        if (config.sourceActive[4]) {
            try this.getUMAPrice(asset) returns (PriceData memory priceData) {
                if (validatePrice(asset, priceData)) {
                    sourcePrices[asset][4] = priceData;
                    validSources++;
                    totalPrice += priceData.price;
                    minPrice = min(minPrice, priceData.price);
                    maxPrice = max(maxPrice, priceData.price);
                }
            } catch {
                emit SourceFailure(asset, 4, "UMA source failed");
            }
        }

        if (validSources < MIN_SOURCES) {
            revert InsufficientSources(asset, validSources, MIN_SOURCES);
        }

        // Calculate median price and confidence
        uint256 medianPrice = calculateMedianPrice(asset, validSources);
        uint256 confidence = calculateConfidence(asset, medianPrice, minPrice, maxPrice, validSources);

        // Update aggregated price
        latestAggregatedPrices[asset] = AggregatedPrice({
            price: medianPrice,
            timestamp: block.timestamp,
            confidence: confidence,
            sourcesUsed: validSources,
            isValid: true
        });

        emit AggregatedPriceUpdated(
            asset,
            medianPrice,
            confidence,
            validSources
        );
    }

    function getChainlinkPrice(string memory asset) 
        external 
        view 
        returns (PriceData memory) 
    {
        address feedAddress = oracleConfigs[asset].chainlinkFeed;
        if (feedAddress == address(0)) revert SourceUnavailable(asset, 1);

        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        require(price > 0, "Invalid price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price");

        return PriceData({
            price: uint256(price),
            timestamp: updatedAt,
            confidence: calculateSourceConfidence(updatedAt),
            source: 1,
            isOutlier: false
        });
    }

    function getRedStonePrice(string memory asset) 
        external 
        view 
        returns (PriceData memory) 
    {
        bytes32 feedId = oracleConfigs[asset].redstoneFeedId;
        if (feedId == bytes32(0)) revert SourceUnavailable(asset, 2);

        uint256 price = getOracleNumericValueFromTxMsg(feedId);
        require(price > 0, "Invalid price");

        return PriceData({
            price: price,
            timestamp: block.timestamp,
            confidence: 90, // RedStone typically has high confidence
            source: 2,
            isOutlier: false
        });
    }

    function getAPI3Price(string memory asset) 
        external 
        view 
        returns (PriceData memory) 
    {
        bytes32 feedId = oracleConfigs[asset].api3FeedId;
        if (feedId == bytes32(0)) revert SourceUnavailable(asset, 3);

        // API3 price fetching logic would go here
        // This is a placeholder implementation
        return PriceData({
            price: 0,
            timestamp: block.timestamp,
            confidence: 0,
            source: 3,
            isOutlier: false
        });
    }

    function getUMAPrice(string memory asset) 
        external 
        view 
        returns (PriceData memory) 
    {
        address feedAddress = oracleConfigs[asset].umaFeed;
        if (feedAddress == address(0)) revert SourceUnavailable(asset, 4);

        // UMA price fetching logic would go here
        // This is a placeholder implementation
        return PriceData({
            price: 0,
            timestamp: block.timestamp,
            confidence: 0,
            source: 4,
            isOutlier: false
        });
    }

    function validatePrice(string memory asset, PriceData memory priceData) 
        internal 
        view 
        returns (bool) 
    {
        if (priceData.price == 0) return false;
        if (priceData.confidence < MIN_CONFIDENCE) return false;
        if (block.timestamp - priceData.timestamp > oracleConfigs[asset].heartbeat) return false;

        AggregatedPrice memory lastPrice = latestAggregatedPrices[asset];
        if (lastPrice.isValid) {
            uint256 deviation = calculateDeviation(priceData.price, lastPrice.price);
            if (deviation > MAX_PRICE_DEVIATION) {
                emit PriceOutlierDetected(asset, priceData.source, priceData.price, lastPrice.price);
                return false;
            }
        }

        return true;
    }

    function calculateSourceConfidence(uint256 timestamp) 
        internal 
        view 
        returns (uint256) 
    {