// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract IDO is Ownable {
    using SafeERC20 for IERC20Metadata;

    struct Vesting {
        uint256 percent;
        uint256 timestamp;
    }

    enum CampaignStatus {
        INVALID,
        ACTIVE,
        SUCCESS,
        FAIL
    }

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

    uint256 public campaignId;
    uint256 public constant PRECISION = 1e18;

    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => mapping(address => uint256)) private _userAllocations;
    mapping(uint256 => mapping(address => uint256)) private _userClaimed;

    event CreateCampaign(uint256 indexed campaignId);
    event ApproveCampaign(uint256 indexed campaignId, address indexed owner);
    event JoinCampaign(uint256 indexed campaignId, address indexed user, uint256 amount);

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

    function approve(uint256 _campaignId, address owner) external onlyOwner {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.saleEndTime < block.timestamp, "Too early to approve");

        //FAIL
        if (campaign.totalAlloc < campaign.minGoal) {
            campaign.status = CampaignStatus.FAIL;
        } else {
            campaign.status = CampaignStatus.SUCCESS;
            IERC20Metadata(campaign.tokenBuy).safeTransfer(owner, campaign.totalAlloc);
        }

        emit ApproveCampaign(_campaignId, owner);
    }

    function join(uint256 _campaignId, uint256 amount) external {
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
        IERC20Metadata(campaign.tokenBuy).safeTransferFrom(msg.sender, address(this), amount);

        emit JoinCampaign(_campaignId, msg.sender, amount);
    }

    function claim(uint256 _campaignId) external {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.status == CampaignStatus.SUCCESS, "Campaign is not successful");

        uint256 claimable = _getTotalClaimable(_campaignId, msg.sender);
        _userClaimed[_campaignId][msg.sender] += claimable;
        uint256 amountToSend = ((claimable * (10**(18 - IERC20Metadata(campaign.tokenBuy).decimals()))) *
            campaign.conversionRate) / PRECISION;
        IERC20Metadata(campaign.tokenSell).safeTransfer(
            msg.sender,
            amountToSend / (10**(18 - IERC20Metadata(campaign.tokenSell).decimals()))
        );
    }

    function refund(uint256 _campaignId) external {
        Campaign storage campaign = _campaigns[_campaignId];
        require(campaign.status == CampaignStatus.FAIL, "Campaign did not fail");
        require(_userAllocations[_campaignId][msg.sender] > 0, "No allocation to refund");

        IERC20Metadata(campaign.tokenBuy).safeTransfer(msg.sender, _userAllocations[_campaignId][msg.sender]);
        _userAllocations[_campaignId][msg.sender] = 0;
    }

    function _getTotalClaimable(uint256 _campaignId, address owner) public view returns (uint256) {
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

    function getCampaign(uint256 _campaignId) external view returns (Campaign memory) {
        return _campaigns[_campaignId];
    }

    function getUserInfo(uint256 _campaignId, address user)
        external
        view
        returns (uint256 allocation, uint256 claimed)
    {
        allocation = _userAllocations[_campaignId][user];
        claimed = (_userClaimed[_campaignId][user] * _campaigns[_campaignId].conversionRate) / PRECISION;
    }
}
