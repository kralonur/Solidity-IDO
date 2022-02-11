// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Simple IDO contract
 * @author Me
 */
contract IDO is Ownable {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant PRECISION = 1e18;
    /// Latest campaign id
    uint256 public campaignId;

    enum CampaignStatus {
        INVALID,
        ACTIVE,
        SUCCESS,
        FAIL
    }

    /**
     * @dev This struct holds information about the vesting
     * @param percent Percentage that user able to claim after timestamp ended
     * @param timestamp Time period for to use after {Campaign.saleEndTime} ends
     */
    struct Vesting {
        uint256 percent;
        uint256 timestamp;
    }

    /**
     * @dev This struct holds information about the campaign
     * @param tokenBuy Token buy address
     * @param tokenSell Token sell address
     * @param totalAlloc Current total allocation on campaign
     * @param minAlloc Minimum allocation amount per user
     * @param maxAlloc Maximum allocation amount per user
     * @param minGoal Minimum amount of tokens for campaign to be successful
     * @param maxGoal Maximum amount of tokens that campaign needs
     * @param conversionRate Coversion rate between token buy-sell (1 tokenA = conversionRate/{PRECISION} tokenB)
     * @param saleStartTime Sale start time for campaign
     * @param saleEndTime Sale end time for campaign
     * @param status campaign status, see {CampaignStatus}
     * @param vestings vestings for campaign, see {Vesting}
     */
    struct Campaign {
        address tokenBuy;
        address tokenSell;
        uint256 totalAlloc;
        uint256 minAlloc;
        uint256 maxAlloc;
        uint256 minGoal;
        uint256 maxGoal;
        uint256 conversionRate;
        uint256 saleStartTime;
        uint256 saleEndTime;
        CampaignStatus status;
        Vesting[] vestings;
    }

    /// A mapping for storing campaigns with their ids
    mapping(uint256 => Campaign) private _campaigns;
    /// A mapping for storing user allocations with campaigns ids and user addresses
    mapping(uint256 => mapping(address => uint256)) private _userAllocations;
    /// A mapping for storing user claimed amounts with campaigns ids and user addresses
    mapping(uint256 => mapping(address => uint256)) private _userClaimed;

    /**
     * @dev Emitted when a campaign created
     * @param campaignId The address of the campaign
     */
    event CreateCampaign(uint256 indexed campaignId);
    /**
     * @dev Emitted when a campaign approved
     * @param campaignId The address of the campaign
     * @param owner The address of funds receiver (in case campaign succesful)
     */
    event ApproveCampaign(uint256 indexed campaignId, address indexed owner);
    /**
     * @dev Emitted when a user joined to campaign
     * @param campaignId The address of the campaign
     * @param user The address of the user
     * @param amount The amount of tokens user joined campaign to
     */
    event JoinCampaign(uint256 indexed campaignId, address indexed user, uint256 amount);

    /**
     * @dev Creates campaign
     * @dev See {Campaign}
     */
    function create(
        address tokenBuy,
        address tokenSell,
        uint256 minAlloc,
        uint256 maxAlloc,
        uint256 minGoal,
        uint256 maxGoal,
        uint256 conversionRate,
        uint256 saleStartTime,
        uint256 saleEndTime,
        Vesting[] calldata vestings
    ) external onlyOwner {
        Campaign storage campaign = _campaigns[campaignId];
        campaign.tokenBuy = tokenBuy;
        campaign.tokenSell = tokenSell;
        campaign.minAlloc = minAlloc;
        campaign.maxAlloc = maxAlloc;
        campaign.minGoal = minGoal;
        campaign.maxGoal = maxGoal;
        campaign.conversionRate = conversionRate;
        campaign.saleStartTime = saleStartTime;
        campaign.saleEndTime = saleEndTime;
        campaign.status = CampaignStatus.ACTIVE;

        uint256 totalPercentage;
        for (uint256 i = 0; i < vestings.length; i++) {
            _campaigns[campaignId].vestings.push(
                Vesting(vestings[i].percent, campaign.saleEndTime + vestings[i].timestamp)
            );
            totalPercentage += vestings[i].percent;
        }

        require(totalPercentage == 100 * PRECISION, "Total percentage should be 100");

        emit CreateCampaign(campaignId);
        campaignId += 1;
    }

    /**
     * @dev Approves a campaign
     * @param _campaignId The id of the campaign
     * @param owner The address of funds receiver (in case campaign succesful)
     */
    function approve(uint256 _campaignId, address owner) external onlyOwner {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.saleEndTime < block.timestamp, "Too early to approve");

        //FAIL
        if (campaign.totalAlloc < campaign.minGoal) {
            campaign.status = CampaignStatus.FAIL;
        } else {
            campaign.status = CampaignStatus.SUCCESS;
            if (campaign.tokenBuy == address(0)) {
                (bool sent, ) = owner.call{ value: campaign.totalAlloc }("");
                require(sent, "Failed to send Ether");
            } else IERC20Metadata(campaign.tokenBuy).safeTransfer(owner, campaign.totalAlloc);
        }

        emit ApproveCampaign(_campaignId, owner);
    }

    /// @dev See {_join}
    function join(uint256 _campaignId, uint256 amount) external {
        _join(_campaignId, amount);
    }

    /// @dev See {_join}
    function join(uint256 _campaignId) external payable {
        uint256 amount = msg.value;
        _join(_campaignId, amount);
    }

    /**
     * @dev Claims the {Campaign.tokenSell} tokens, in case campaign is successful
     * @param _campaignId The id of the campaign
     */
    function claim(uint256 _campaignId) external {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.status == CampaignStatus.SUCCESS, "Campaign is not successful");

        uint256 claimable = _getTotalClaimable(_campaignId, msg.sender);
        _userClaimed[_campaignId][msg.sender] += claimable;

        uint256 tokenBuyMultiplier = campaign.tokenBuy == address(0)
            ? _calculateMultiplier(18)
            : _calculateMultiplier(IERC20Metadata(campaign.tokenBuy).decimals());

        uint256 amountToSend = ((claimable * tokenBuyMultiplier) * campaign.conversionRate) / PRECISION;
        IERC20Metadata(campaign.tokenSell).safeTransfer(
            msg.sender,
            amountToSend / _calculateMultiplier(IERC20Metadata(campaign.tokenSell).decimals())
        );
    }

    /**
     * @dev Refunds the funded tokens back to owners, in case campaign did failed
     * @param _campaignId The id of the campaign
     */
    function refund(uint256 _campaignId) external payable {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.status == CampaignStatus.FAIL, "Campaign did not fail");
        require(_userAllocations[_campaignId][msg.sender] > 0, "No allocation to refund");

        if (campaign.tokenBuy != address(0))
            IERC20Metadata(campaign.tokenBuy).safeTransfer(msg.sender, _userAllocations[_campaignId][msg.sender]);
        else {
            (bool sent, ) = msg.sender.call{ value: _userAllocations[_campaignId][msg.sender] }("");
            require(sent, "Failed to send Ether");
        }

        _userAllocations[_campaignId][msg.sender] = 0;
    }

    /**
     * @dev Gets campaign information
     * @param _campaignId The id of the campaign
     * @return campaign info
     */
    function getCampaign(uint256 _campaignId) external view returns (Campaign memory) {
        return _campaigns[_campaignId];
    }

    /**
     * @dev Gets user information
     * @param _campaignId The id of the campaign
     * @param user The address of the user
     * @return allocation user allocation
     * @return claimed user claimed amount
     */
    function getUserInfo(uint256 _campaignId, address user)
        external
        view
        returns (uint256 allocation, uint256 claimed)
    {
        allocation = _userAllocations[_campaignId][user];
        claimed = (_userClaimed[_campaignId][user] * _campaigns[_campaignId].conversionRate) / PRECISION;
    }

    /**
     * @dev Calculates claimable amount for the user (PS: claimable amount is in the form of {Campaign.tokenBuy})
     * @param _campaignId The id of the campaign
     * @param owner The address of the funds owner
     * @return total claimable amount
     */
    function _getTotalClaimable(uint256 _campaignId, address owner) private view returns (uint256) {
        Campaign memory campaign = _campaigns[_campaignId];
        uint256 claimed = _userClaimed[_campaignId][owner];
        uint256 userAllocation = _userAllocations[_campaignId][owner];

        uint256 claimableAmount;

        for (uint256 i = 0; i < campaign.vestings.length; i++) {
            if (campaign.vestings[i].timestamp < block.timestamp)
                claimableAmount += (userAllocation * campaign.vestings[i].percent) / (100 * PRECISION);
        }

        return claimableAmount - claimed;
    }

    /**
     * @dev Calculates the multiplier for amount to send
     * @param decimals decimals
     * @return multiplier
     */
    function _calculateMultiplier(uint256 decimals) private pure returns (uint256) {
        return 10**(18 - decimals);
    }

    /**
     * @dev Joins to given campaign
     * @param _campaignId The id of the campaign
     * @param amount The amount of tokens user puts into the campaign
     */
    function _join(uint256 _campaignId, uint256 amount) private {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.status == CampaignStatus.ACTIVE, "Campaign is not active");
        require(
            campaign.saleStartTime < block.timestamp && campaign.saleEndTime > block.timestamp,
            "You cannot join now"
        );
        require(campaign.maxAlloc >= amount && campaign.minAlloc <= amount, "Amount is not right");
        require(campaign.maxGoal >= campaign.totalAlloc + amount, "Amount exceeds the goal");

        _userAllocations[_campaignId][msg.sender] += amount;
        campaign.totalAlloc += amount;

        if (campaign.tokenBuy != address(0))
            IERC20Metadata(campaign.tokenBuy).safeTransferFrom(msg.sender, address(this), amount);

        emit JoinCampaign(_campaignId, msg.sender, amount);
    }
}
