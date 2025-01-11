// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract QuantumMLCryptoPredictor is ReentrancyGuard, Pausable, Ownable {
    using SafeMath for uint256;
    using Strings for string;

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 decimals;
        uint256 confidence; // Confidence score of the price (0-100)
        address oracle;     // Chainlink oracle address
    }

    struct Prediction {
        uint256 predictedPrice;
        uint256 timestamp;
        bool verified;
        uint256 confidence; // Confidence score of the prediction (0-100)
    }

    struct RateLimit {
        uint256 lastPredictionTime;
        uint256 predictionCount;
        uint256 dailyLimit;
    }

    // Constants
    uint256 public constant MAX_INPUT_LENGTH = 100;
    uint256 public constant PREDICTION_TIMEOUT = 24 hours;
    uint256 public constant MIN_PREDICTION_INTERVAL = 1 hours;
    uint256 public constant MAX_DAILY_PREDICTIONS = 5;
    uint256 public constant CONFIDENCE_THRESHOLD = 70;

    // State variables
    uint256 public predictionFee;
    mapping(string => bool) public supportedCryptos;
    mapping(string => PriceData) public cryptoPrices;
    mapping(address => bool) public registeredUsers;
    mapping(address => mapping(string => mapping(uint256 => uint256[]))) public userInputs;
    mapping(address => mapping(string => Prediction)) public userPredictions;
    mapping(address => RateLimit) public userRateLimits;
    mapping(string => AggregatorV3Interface) public priceFeeds;

    // Events
    event UserRegistered(address indexed user, uint256 timestamp);
    event PredictionMade(
        address indexed user,
        string indexed crypto,
        uint256 predictedPrice,
        uint256 confidence,
        uint256 timestamp
    );
    event PriceUpdated(
        string indexed crypto,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 confidence,
        uint256 timestamp
    );
    event CryptoAdded(
        string indexed crypto,
        address oracle,
        uint256 timestamp
    );
    event CryptoRemoved(string indexed crypto, uint256 timestamp);
    event PredictionVerified(
        address indexed user,
        string indexed crypto,
        bool success,
        uint256 accuracy,
        uint256 timestamp
    );
    event RateLimitExceeded(address indexed user, uint256 timestamp);
    event OracleUpdated(string indexed crypto, address oracle, uint256 timestamp);

    // Custom errors for gas optimization
    error RateLimitExceeded(address user);
    error InvalidPredictionInterval();
    error InsufficientConfidence();
    error InvalidOracle();
    error UnsupportedCrypto();

    modifier validCrypto(string memory crypto) {
        if (!supportedCryptos[crypto]) revert UnsupportedCrypto();
        require(bytes(crypto).length > 0, "Invalid cryptocurrency symbol");
        _;
    }

    modifier validInputData(uint256[] memory inputData) {
        require(inputData.length > 0, "Empty input data");
        require(inputData.length <= MAX_INPUT_LENGTH, "Input data too long");
        _;
    }

    modifier checkRateLimit() {
        RateLimit storage rateLimit = userRateLimits[msg.sender];
        
        // Reset daily count if 24 hours have passed
        if (block.timestamp.sub(rateLimit.lastPredictionTime) >= 24 hours) {
            rateLimit.predictionCount = 0;
        }

        // Check if user has exceeded daily limit
        if (rateLimit.predictionCount >= MAX_DAILY_PREDICTIONS) {
            emit RateLimitExceeded(msg.sender, block.timestamp);
            revert RateLimitExceeded(msg.sender);
        }

        // Check minimum interval between predictions
        if (block.timestamp.sub(rateLimit.lastPredictionTime) < MIN_PREDICTION_INTERVAL) {
            revert InvalidPredictionInterval();
        }
        _;
    }

    constructor(uint256 _predictionFee) {
        require(_predictionFee > 0, "Invalid prediction fee");
        predictionFee = _predictionFee;
    }

    function register() external whenNotPaused {
        require(!registeredUsers[msg.sender], "User already registered");
        require(msg.sender != address(0), "Invalid address");
        
        registeredUsers[msg.sender] = true;
        userRateLimits[msg.sender] = RateLimit({
            lastPredictionTime: 0,
            predictionCount: 0,
            dailyLimit: MAX_DAILY_PREDICTIONS
        });

        emit UserRegistered(msg.sender, block.timestamp);
    }

    function makePrediction(
        string memory crypto,
        uint256[] memory inputData
    ) external payable whenNotPaused nonReentrant validCrypto(crypto) validInputData(inputData) checkRateLimit {
        require(registeredUsers[msg.sender], "User not registered");
        require(msg.value == predictionFee, "Incorrect prediction fee");

        // Get current price from Chainlink oracle
        (uint256 currentPrice, uint256 confidence) = getOraclePrice(crypto);
        require(currentPrice > 0, "Invalid oracle price");
        
        if (confidence < CONFIDENCE_THRESHOLD) revert InsufficientConfidence();

        // Make prediction using quantum ML
        (uint256 prediction, uint256 predictionConfidence) = predictPrice(inputData, currentPrice);
        require(prediction > 0, "Invalid prediction");

        // Update rate limit
        RateLimit storage rateLimit = userRateLimits[msg.sender];
        rateLimit.lastPredictionTime = block.timestamp;
        rateLimit.predictionCount = rateLimit.predictionCount.add(1);

        // Store prediction
        userInputs[msg.sender][crypto][block.timestamp] = inputData;
        userPredictions[msg.sender][crypto] = Prediction({
            predictedPrice: prediction,
            timestamp: block.timestamp,
            verified: false,
            confidence: predictionConfidence
        });

        emit PredictionMade(
            msg.sender,
            crypto,
            prediction,
            predictionConfidence,
            block.timestamp
        );
    }

    function getOraclePrice(string memory crypto) public view returns (uint256 price, uint256 confidence) {
        AggregatorV3Interface oracle = priceFeeds[crypto];
        if (address(oracle) == address(0)) revert InvalidOracle();

        (
            uint80 roundID,
            int256 oraclePrice,
            ,
            uint256 timestamp,
            uint80 answeredInRound
        ) = oracle.latestRoundData();

        require(oraclePrice > 0, "Invalid oracle price");
        require(timestamp > 0, "Stale oracle price");
        require(answeredInRound >= roundID, "Oracle round incomplete");

        // Calculate confidence based on price staleness
        uint256 staleness = block.timestamp - timestamp;
        confidence = staleness < 1 hours ? 100 : staleness < 2 hours ? 80 : 60;

        return (uint256(oraclePrice), confidence);
    }

    function predictPrice(uint256[] memory inputData, uint256 currentPrice) 
        internal
        pure
        returns (uint256 prediction, uint256 confidence)
    {
        // QUANTUM ML IMPLEMENTATION PLACEHOLDER
        // In production, this would integrate with quantum computing resources
        uint256 sum = 0;
        uint256 weightedSum = 0;
        uint256 weight = 100;

        for (uint256 i = 0; i < inputData.length; i++) {
            sum = sum.add(inputData[i].mul(weight).div(100));
            weightedSum = weightedSum.add(weight);
            weight = weight.mul(95).div(100); // Decay weight by 5%
        }

        prediction = sum.mul(currentPrice).div(weightedSum);
        
        // Calculate confidence based on input data quality
        confidence = 100 - (
            (prediction > currentPrice ? 
                prediction - currentPrice : 
                currentPrice - prediction
            ) * 100 / currentPrice
        );

        return (prediction, confidence);
    }

    function setOracleAddress(string memory crypto, address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle address");
        priceFeeds[crypto] = AggregatorV3Interface(oracle);
        emit OracleUpdated(crypto, oracle, block.timestamp);
    }

    function updateUserRateLimit(address user, uint256 newLimit) external onlyOwner {
        require(user != address(0), "Invalid address");
        require(newLimit > 0, "Invalid limit");
        userRateLimits[user].dailyLimit = newLimit;
    }

    function verifyPrediction(string memory crypto) 
        external 
        whenNotPaused 
        validCrypto(crypto) 
        returns (bool) 
    {
        Prediction storage prediction = userPredictions[msg.sender][crypto];
        require(prediction.timestamp > 0, "No prediction found");
        require(!prediction.verified, "Prediction already verified");
        require(
            block.timestamp <= prediction.timestamp + PREDICTION_TIMEOUT,
            "Prediction expired"
        );

        (uint256 actualPrice, uint256 confidence) = getOraclePrice(crypto);
        require(confidence >= CONFIDENCE_THRESHOLD, "Insufficient oracle confidence");

        uint256 tolerance = actualPrice.mul(prediction.confidence).div(1000); // Dynamic tolerance based on confidence
        bool success = (prediction.predictedPrice >= actualPrice.sub(tolerance)) &&
            (prediction.predictedPrice <= actualPrice.add(tolerance));

        uint256 accuracy = 100 - (
            (prediction.predictedPrice > actualPrice ? 
                prediction.predictedPrice - actualPrice : 
                actualPrice - prediction.predictedPrice
            ) * 100 / actualPrice
        );

        prediction.verified = true;
        emit PredictionVerified(msg.sender, crypto, success, accuracy, block.timestamp);
        return success;
    }

    // Additional helper functions remain the same

    function getUserStats(address user) 
        external 
        view 
        returns (
            uint256 totalPredictions,
            uint256 successfulPredictions,
            uint256 averageAccuracy
        )
    {
        // Implementation details
        return (0, 0, 0); // Placeholder return
    }
}