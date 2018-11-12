pragma solidity ^0.4.24;


import "./Staff.sol";
import "./StaffUtil.sol";
import "./Token.sol";
import "./DiscountStructs.sol";
import "./PromoCodes.sol";


contract Crowdsale is StaffUtil {
	using SafeMath for uint256;

	Token tokenContract;
	PromoCodes promoCodesContract;
	DiscountStructs discountStructsContract;

	address ethFundsWallet;
	uint256 referralBonusPercent;
	uint256 startDate;

	uint256 crowdsaleStartDate;
	uint256 endDate;
	uint256 tokenDecimals;
	uint256 tokenRate;
	uint256 tokensForSaleCap;
	uint256 minPurchaseInWei;
	uint256 maxInvestorContributionInWei;
	bool paused;
	bool finalized;
	uint256 weiRaised;
	uint256 soldTokens;
	uint256 bonusTokens;
	uint256 sentTokens;
	uint256 claimedSoldTokens;
	uint256 claimedBonusTokens;
	uint256 claimedSentTokens;
	mapping(address => Investor) public investors;

	enum InvestorStatus {UNDEFINED, WHITELISTED, BLOCKED}

	struct Investor {
		InvestorStatus status;
		uint256 contributionInWei;
		uint256 purchasedTokens;
		uint256 bonusTokens;
		uint256 referralTokens;
		uint256 receivedTokens;
		uint claimedPurchasePercent;
		mapping(uint => bool) claimedPurchased;
		uint claimedBonusPercent;
		mapping(uint => bool) claimedBonus;
		TokensPurchase[] tokensPurchasesForRefund;
	}

	ClaimLock[] purchaseClaimLocks;
	ClaimLock[] bonusClaimLocks;

	struct ClaimLock {
		uint date;
		uint percent;
	}

	function getPurchaseClaimLocks() external constant returns (uint[], uint[]) {
		uint[] memory dates = new uint[](purchaseClaimLocks.length);
		uint[] memory percents = new uint[](purchaseClaimLocks.length);
		for (uint i = 0; i < purchaseClaimLocks.length; i++) {
			dates[i] = purchaseClaimLocks[i].date;
			percents[i] = purchaseClaimLocks[i].percent;
		}
		return (dates, percents);
	}

	function getBonusClaimLocks() external view returns (uint[], uint[]) {
		uint[] memory dates = new uint[](bonusClaimLocks.length);
		uint[] memory percents = new uint[](bonusClaimLocks.length);
		for (uint i = 0; i < bonusClaimLocks.length; i++) {
			dates[i] = bonusClaimLocks[i].date;
			percents[i] = bonusClaimLocks[i].percent;
		}
		return (dates, percents);
	}

	struct TokensPurchase {
		uint256 value;
		uint256 amount;
		uint256 bonus;
		address referrer;
		uint256 referrerSentAmount;
	}

	event InvestorWhitelisted(address indexed investor, uint timestamp, address byStaff);
	event InvestorBlocked(address indexed investor, uint timestamp, address byStaff);
	event TokensPurchased(
		address indexed investor,
		uint indexed purchaseId,
		uint256 value,
		uint256 purchasedAmount,
		uint256 promoCodeAmount,
		uint256 discountPhaseAmount,
		uint256 discountStructAmount,
		address indexed referrer,
		uint256 referrerSentAmount,
		uint timestamp
	);
	event TokensPurchaseRefunded(
		address indexed investor,
		uint indexed purchaseId,
		uint256 value,
		uint256 amount,
		uint256 bonus,
		uint timestamp,
		address byStaff
	);
	event TokensSent(address indexed investor, uint256 amount, uint timestamp, address byStaff);
	event TokensClaimed(
		address indexed investor,
		uint256 purchased,
		uint256 bonus,
		uint256 referral,
		uint256 received,
		uint timestamp,
		address byStaff
	);

	constructor (
		uint256[9] uint256Args,
		address[4] addressArgs
	) StaffUtil(Staff(addressArgs[3])) public {

		// uint256 args
		startDate = uint256Args[0];
		crowdsaleStartDate = uint256Args[1];
		endDate = uint256Args[2];
		tokenDecimals = uint256Args[3];
		tokenRate = uint256Args[4];
		tokensForSaleCap = uint256Args[5];
		minPurchaseInWei = uint256Args[6];
		maxInvestorContributionInWei = uint256Args[7];
		referralBonusPercent = uint256Args[8];

		// address args
		ethFundsWallet = addressArgs[0];
		promoCodesContract = PromoCodes(addressArgs[1]);
		discountStructsContract = DiscountStructs(addressArgs[2]);

		require(startDate < crowdsaleStartDate);
		require(crowdsaleStartDate < endDate);
		require(tokenDecimals > 0);
		require(tokenRate > 0);
		require(tokensForSaleCap > 0);
		require(minPurchaseInWei <= maxInvestorContributionInWei);
		require(ethFundsWallet != address(0));
	}

	function getState() external view returns (bool[2] boolArgs, uint256[16] uint256Args, address[5] addressArgs) {
		boolArgs[0] = paused;
		boolArgs[1] = finalized;
		uint256Args[0] = weiRaised;
		uint256Args[1] = soldTokens;
		uint256Args[2] = bonusTokens;
		uint256Args[3] = sentTokens;
		uint256Args[4] = claimedSoldTokens;
		uint256Args[5] = claimedBonusTokens;
		uint256Args[6] = claimedSentTokens;
		uint256Args[7] = startDate;
		uint256Args[8] = crowdsaleStartDate;
		uint256Args[9] = endDate;
		uint256Args[10] = tokenRate;
		uint256Args[11] = tokenDecimals;
		uint256Args[12] = minPurchaseInWei;
		uint256Args[13] = maxInvestorContributionInWei;
		uint256Args[14] = referralBonusPercent;
		uint256Args[15] = getTokensForSaleCap();
		addressArgs[0] = staffContract;
		addressArgs[1] = ethFundsWallet;
		addressArgs[2] = promoCodesContract;
		addressArgs[3] = discountStructsContract;
		addressArgs[4] = tokenContract;
	}

	function fitsTokensForSaleCap(uint256 _amount) public view returns (bool) {
		return getDistributedTokens().add(_amount) <= getTokensForSaleCap();
	}

	function getTokensForSaleCap() public view returns (uint256) {
		if (tokenContract != address(0)) {
			return tokenContract.balanceOf(this);
		}
		return tokensForSaleCap;
	}

	function getDistributedTokens() public view returns (uint256) {
		return soldTokens.sub(claimedSoldTokens).add(bonusTokens.sub(claimedBonusTokens)).add(sentTokens.sub(claimedSentTokens));
	}

	function setPurchasedTokensClaimLocks(uint[] dates, uint8[] percents) external onlyOwner {
		require(purchaseClaimLocks.length == 0);
		require(dates.length > 0);
		require(dates.length == percents.length);
		uint8 sum = 0;
		for (uint i = 0; i < percents.length; i++) {
			require(percents[i] > 0);
			purchaseClaimLocks.push(ClaimLock(dates[i], percents[i]));
			sum = sum + percents[i];
		}
		require(sum == 100);
	}

	function editPurchaseTokensClaimLocks(uint[] dates) external onlyOwner {
		require(purchaseClaimLocks.length > 0);
		require(purchaseClaimLocks.length == dates.length);
		for (uint i = 0; i < dates.length; i++) {
			purchaseClaimLocks[i].date = dates[i];
		}
	}

	function setBonusTokensClaimLocks(uint[] dates, uint8[] percents) external onlyOwner {
		require(bonusClaimLocks.length == 0);
		require(dates.length > 0);
		require(dates.length == percents.length);
		uint8 sum = 0;
		for (uint i = 0; i < percents.length; i++) {
			require(percents[i] > 0);
			bonusClaimLocks.push(ClaimLock(dates[i], percents[i]));
			sum = sum + percents[i];
		}
		require(sum == 100);
	}

	function editBonusTokensClaimLocks(uint[] dates) external onlyOwner {
		require(bonusClaimLocks.length > 0);
		require(bonusClaimLocks.length == dates.length);
		for (uint i = 0; i < dates.length; i++) {
			bonusClaimLocks[i].date = dates[i];
		}
	}

	function setTokenContract(Token token) external onlyOwner {
		require(token.decimals() == tokenDecimals);
		require(tokenContract == address(0));
		require(token != address(0));
		tokenContract = token;
	}

	function getInvestorClaimedTokens(address _investor) external view returns (uint256) {
		if (tokenContract != address(0)) {
			return tokenContract.balanceOf(_investor);
		}
		return 0;
	}

	function whitelistInvestors(address[] _investors) external onlyOwnerOrStaff {
		for (uint256 i = 0; i < _investors.length; i++) {
			if (_investors[i] != address(0) && investors[_investors[i]].status != InvestorStatus.WHITELISTED) {
				investors[_investors[i]].status = InvestorStatus.WHITELISTED;
				emit InvestorWhitelisted(_investors[i], now, msg.sender);
			}
		}
	}

	function blockInvestors(address[] _investors) external onlyOwnerOrStaff {
		for (uint256 i = 0; i < _investors.length; i++) {
			if (_investors[i] != address(0) && investors[_investors[i]].status != InvestorStatus.BLOCKED) {
				investors[_investors[i]].status = InvestorStatus.BLOCKED;
				emit InvestorBlocked(_investors[i], now, msg.sender);
			}
		}
	}

	function setCrowdsaleStartDate(uint256 _date) external onlyOwner {
		crowdsaleStartDate = _date;
	}

	function setEndDate(uint256 _date) external onlyOwner {
		endDate = _date;
	}

	function setMinPurchaseInWei(uint256 _minPurchaseInWei) external onlyOwner {
		minPurchaseInWei = _minPurchaseInWei;
	}

	function setMaxInvestorContributionInWei(uint256 _maxInvestorContributionInWei) external onlyOwner {
		require(minPurchaseInWei <= _maxInvestorContributionInWei);
		maxInvestorContributionInWei = _maxInvestorContributionInWei;
	}

	function changeTokenRate(uint256 _tokenRate) external onlyOwner {
		require(_tokenRate > 0);
		tokenRate = _tokenRate;
	}

	function buyTokens(bytes32 _promoCode, address _referrer) external payable {
		require(!finalized);
		require(!paused);
		require(startDate < now);
		require(investors[msg.sender].status == InvestorStatus.WHITELISTED);
		require(msg.value > 0);
		require(msg.value >= minPurchaseInWei);
		require(investors[msg.sender].contributionInWei.add(msg.value) <= maxInvestorContributionInWei);

		uint purchaseId = investors[msg.sender].tokensPurchasesForRefund.push(TokensPurchase({
			value : 0,
			amount : 0,
			bonus : 0,
			referrer : 0x0,
			referrerSentAmount : 0
			})) - 1;

		// calculate purchased amount
		uint256 purchasedAmount;
		if (tokenDecimals > 18) {
			purchasedAmount = msg.value.mul(tokenRate).mul(10 ** (tokenDecimals - 18));
		} else if (tokenDecimals < 18) {
			purchasedAmount = msg.value.mul(tokenRate).div(10 ** (18 - tokenDecimals));
		} else {
			purchasedAmount = msg.value.mul(tokenRate);
		}

		// calculate total amount, this includes promo code amount or discount amount
		uint256 promoCodeBonusAmount = promoCodesContract.applyBonusAmount(msg.sender, purchasedAmount, _promoCode);
		uint256 discountStructBonusAmount = discountStructsContract.getBonus(msg.sender, purchasedAmount, msg.value);
		uint256 bonusAmount = promoCodeBonusAmount.add(discountStructBonusAmount);

		// update referrer's referral tokens
		uint256 referrerBonusAmount;
		address referrerAddr;
		if (
			_referrer != address(0)
			&& msg.sender != _referrer
			&& investors[_referrer].status == InvestorStatus.WHITELISTED
		) {
			referrerBonusAmount = purchasedAmount * referralBonusPercent / 100;
			referrerAddr = _referrer;
		}

		// check that calculated tokens will not exceed tokens for sale cap
		require(fitsTokensForSaleCap(purchasedAmount.add(bonusAmount).add(referrerBonusAmount)));

		// update crowdsale total amount of capital raised
		weiRaised = weiRaised.add(msg.value);
		soldTokens = soldTokens.add(purchasedAmount);
		bonusTokens = bonusTokens.add(bonusAmount).add(referrerBonusAmount);

		// update referrer's bonus tokens
		investors[referrerAddr].referralTokens = investors[referrerAddr].referralTokens.add(referrerBonusAmount);

		// update investor's purchased tokens
		investors[msg.sender].purchasedTokens = investors[msg.sender].purchasedTokens.add(purchasedAmount);

		// update investor's bonus tokens
		investors[msg.sender].bonusTokens = investors[msg.sender].bonusTokens.add(bonusAmount);

		// update investor's tokens eth value
		investors[msg.sender].contributionInWei = investors[msg.sender].contributionInWei.add(msg.value);

		// update investor's tokens purchases
		investors[msg.sender].tokensPurchasesForRefund[purchaseId].value = msg.value;
		investors[msg.sender].tokensPurchasesForRefund[purchaseId].amount = purchasedAmount;
		investors[msg.sender].tokensPurchasesForRefund[purchaseId].bonus = bonusAmount;
		investors[msg.sender].tokensPurchasesForRefund[purchaseId].referrer = referrerAddr;
		investors[msg.sender].tokensPurchasesForRefund[purchaseId].referrerSentAmount = referrerBonusAmount;

		// log investor's tokens purchase
		emit TokensPurchased(
			msg.sender,
			purchaseId,
			msg.value,
			purchasedAmount,
			promoCodeBonusAmount,
			0,
			discountStructBonusAmount,
			referrerAddr,
			referrerBonusAmount,
			now
		);

		// forward eth to funds wallet
		require(ethFundsWallet.call.gas(300000).value(msg.value)());
	}

	function sendTokens(address _investor, uint256 _amount) external onlyOwner {
		require(investors[_investor].status == InvestorStatus.WHITELISTED);
		require(_amount > 0);
		require(fitsTokensForSaleCap(_amount));

		// update crowdsale total amount of capital raised
		sentTokens = sentTokens.add(_amount);

		// update investor's received tokens balance
		investors[_investor].receivedTokens = investors[_investor].receivedTokens.add(_amount);

		// log tokens sent action
		emit TokensSent(
			_investor,
			_amount,
			now,
			msg.sender
		);
	}

	function burnUnsoldTokens() external onlyOwner {
		require(tokenContract != address(0));
		require(finalized);

		uint256 tokensToBurn = tokenContract.balanceOf(this).sub(getDistributedTokens());
		require(tokensToBurn > 0);

		tokenContract.burn(tokensToBurn);
	}

	function claimTokens() external {
		require(finalized);
		require(tokenContract != address(0));
		require(!paused);
		require(investors[msg.sender].status == InvestorStatus.WHITELISTED);

		uint256 clPurchasedTokens;
		uint256 clReceivedTokens;
		uint256 clBonusTokens;
		uint256 clRefTokens;

		if (investors[msg.sender].purchasedTokens > 0 || investors[msg.sender].receivedTokens > 0) {
			for (uint i = 0; i < purchaseClaimLocks.length; i++) {
				if (purchaseClaimLocks[i].date < now && !investors[msg.sender].claimedPurchased[i]) {
					investors[msg.sender].claimedPurchased[i] = true;

					uint percent = purchaseClaimLocks[i].percent;
					uint claimedPercent = investors[msg.sender].claimedPurchasePercent;

					uint256 purchased = investors[msg.sender].purchasedTokens.div(100 - claimedPercent).mul(percent);
					uint256 received = investors[msg.sender].receivedTokens.div(100 - claimedPercent).mul(percent);

					investors[msg.sender].claimedPurchasePercent = claimedPercent + percent;

					investors[msg.sender].purchasedTokens = investors[msg.sender].purchasedTokens.sub(purchased);
					investors[msg.sender].receivedTokens = investors[msg.sender].receivedTokens.sub(received);

					claimedSoldTokens = claimedSoldTokens.add(purchased);
					claimedSentTokens = claimedSentTokens.add(received);

					clPurchasedTokens = clPurchasedTokens.add(purchased);
					clReceivedTokens = clReceivedTokens.add(received);
				}
			}
			if (clPurchasedTokens > 0 || clReceivedTokens > 0) {
				tokenContract.transfer(msg.sender, clPurchasedTokens.add(clReceivedTokens));
			}
		}

		if (investors[msg.sender].bonusTokens > 0 || investors[msg.sender].referralTokens > 0) {
			for (i = 0; i < bonusClaimLocks.length; i++) {
				if (bonusClaimLocks[i].date < now && !investors[msg.sender].claimedBonus[i]) {
					investors[msg.sender].claimedBonus[i] = true;

					percent = bonusClaimLocks[i].percent;
					claimedPercent = investors[msg.sender].claimedBonusPercent;

					uint256 bonus = investors[msg.sender].bonusTokens.div(100 - claimedPercent).mul(percent);
					uint256 ref = investors[msg.sender].referralTokens.div(100 - claimedPercent).mul(percent);

					investors[msg.sender].claimedBonusPercent = claimedPercent + percent;

					investors[msg.sender].bonusTokens = investors[msg.sender].bonusTokens.sub(bonus);
					investors[msg.sender].referralTokens = investors[msg.sender].referralTokens.sub(ref);

					claimedBonusTokens = claimedBonusTokens.add(bonus).add(ref);

					clBonusTokens = clBonusTokens.add(bonus);
					clRefTokens = clRefTokens.add(ref);
				}
			}
			if (clBonusTokens > 0 || clRefTokens > 0) {
				tokenContract.transfer(msg.sender, clBonusTokens.add(clRefTokens));
			}
		}

		if (clPurchasedTokens > 0 || clBonusTokens > 0 || clRefTokens > 0 || clReceivedTokens > 0) {
			emit TokensClaimed(msg.sender, clPurchasedTokens, clBonusTokens, clRefTokens, clReceivedTokens, now, msg.sender);
		}
	}

	function refundTokensPurchase(address _investor, uint _purchaseId) external payable onlyOwner {
		require(msg.value > 0);
		require(investors[_investor].tokensPurchasesForRefund[_purchaseId].value == msg.value);

		// update referrer's referral tokens
		address referrer = investors[_investor].tokensPurchasesForRefund[_purchaseId].referrer;
		if (referrer != address(0)) {
			uint256 sentAmount = investors[_investor].tokensPurchasesForRefund[_purchaseId].referrerSentAmount;
			investors[referrer].referralTokens = investors[referrer].referralTokens.sub(sentAmount);
			bonusTokens = bonusTokens.sub(sentAmount);
		}

		// update investor's eth amount
		uint256 purchaseValue = investors[_investor].tokensPurchasesForRefund[_purchaseId].value;
		investors[_investor].contributionInWei = investors[_investor].contributionInWei.sub(purchaseValue);

		// update investor's purchased tokens
		uint256 purchaseAmount = investors[_investor].tokensPurchasesForRefund[_purchaseId].amount;
		investors[_investor].purchasedTokens = investors[_investor].purchasedTokens.sub(purchaseAmount);

		// update investor's bonus tokens
		uint256 bonusAmount = investors[_investor].tokensPurchasesForRefund[_purchaseId].bonus;
		investors[_investor].bonusTokens = investors[_investor].bonusTokens.sub(bonusAmount);

		// update crowdsale total amount of capital raised
		weiRaised = weiRaised.sub(purchaseValue);
		soldTokens = soldTokens.sub(purchaseAmount);
		bonusTokens = bonusTokens.sub(bonusAmount);

		// free up storage used by transaction
		delete (investors[_investor].tokensPurchasesForRefund[_purchaseId]);

		// log investor's tokens purchase refund
		emit TokensPurchaseRefunded(_investor, _purchaseId, purchaseValue, purchaseAmount, bonusAmount, now, msg.sender);

		// forward eth to investor's wallet address
		_investor.transfer(msg.value);
	}

	function setPaused(bool p) external onlyOwner {
		paused = p;
	}

	function finalize() external onlyOwner {
		finalized = true;
	}
}
