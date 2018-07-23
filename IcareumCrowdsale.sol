pragma solidity ^0.4.23;

import './IcareumToken.sol';
import './Adminable.sol';
import './openzeppelin/Pausable.sol';
import './openzeppelin/RefundVault.sol';
import './openzeppelin/SafeMath.sol';

contract IcareumCrowdsale is Adminable, Pausable {
    using SafeMath for uint256;
    // токен
    IcareumToken public token;
    // адрес на который будут поступать средства от продажи токенов после достижения softcap 
    address public fundWallet;
    // хранилище, которое будет содержать средства инвесторов до достижения softcap 
    RefundVault public vault;
    // токены основного сейла
    uint256 public constant mainSaleTokenCap = 80000000; 
    uint256 public mainMintedTokens = 0;
    // токены пресейла
    uint256 public constant presaleTokenCap = 3000000; 
    uint256 public presaleMintedTokens = 0;
    // бонусные токены 
    uint256 public constant bonusTokenCap = 10000000; 
    uint256 public bonusMintedTokens = 0;
    // максимальное количество токенов на каждый этап основного сейла
    uint256 public constant mainsaleTokenCap1 = 10000000; 
    uint256 public constant mainsaleTokenCap2 = 25000000; 
    uint256 public constant mainsaleTokenCap3 = 50000000; 
    uint256 public constant mainsaleTokenCap4 = 80000000; 
    // минимально необходимое эмитированное количество токенов основного сейла для вывода эфира с контракта
    uint256 public constant tokenSoftCap = 4000000; 
    // блок конца продажи основного сейла
    uint256 public endBlock;
    // курс эфира к доллару, определяется как количество веев за 0,1$, т.к. стоимость токена всегда кратна этой сумме
    uint256 public rateWeiFor10Cent; 
    // количество полученных средств в веях
    uint256 public weiRaised = 0; 
    // факт старта продаж
    bool public crowdsaleStarted = false;
    // факт окончания продажи
    bool public crowdsaleFinished = false;    
    // список приглашенных инвесторов
    mapping (address => bool) internal isInvestor;  
    // соответствие реферралов
    mapping (address => address) internal referrerAddr;
    /**
    * событие покупки токенов
    * @param beneficiary тот, кто получил токены
    * @param value сумма в веях, заплаченная за токены
    * @param amount количество переданных токенов
    */
    event TokenPurchase(address indexed beneficiary, uint256 value, uint256 amount);
    // событие начала краудсейла
    event Started();
    // событие окончания краудсейла
    event Finished();
    // событие смены курса токена к доллару
    event RateChanged();
    /** Стадии
	 * - PreSale: Эмиссия токенов, проданных на пресейле
     * - MainSale: Основной краудсейл
     * - BonusDistribution: раздача бонусов после окончания основного сейла
     * - Successed: эмиссия окончена (устанавливается вручную)
     * - Failed: после окончания продажи софткап не достигнут
     */
    enum stateType {PreSale, MainSale, BonusDistribution, Successed, Failed}
    modifier onlyPresale {
     	require(crowdsaleState() == stateType.PreSale);
    	_;
  	}
    modifier onlyMainsale {
     	require(crowdsaleState() == stateType.MainSale);
    	_;
  	}
  	modifier onlyBonusDistribution {
     	require(crowdsaleState() == stateType.BonusDistribution);
    	_;  		
  	}
  	modifier onlyFailed {
     	require(crowdsaleState() == stateType.Failed);
    	_;  		
  	} 
    // статус краудсейла 
    function crowdsaleState() view public returns (stateType) {
    	if(!crowdsaleStarted) return stateType.PreSale;
    	else if(!_mainsaleHasEnded()) return stateType.MainSale;
    	else if(mainMintedTokens < tokenSoftCap) return stateType.Failed;
    	else if(!crowdsaleFinished) return stateType.BonusDistribution;
    	else return stateType.Successed;
    }
    // стоимость токена в веях
    function rateOfTokenInWei() view public returns(uint256) {   
       	return rateWeiFor10Cent.mul(_tokenPriceMultiplier()); 
    }  
    // проверка баланса токенов на адресе
    function tokenBalance(address _addr) view public returns (uint256) {
        return token.balanceOf(_addr);
    }
    function checkIfInvestor(address _addr) view public returns (bool) {
        return isInvestor[_addr];
    }

    ///////////////////////////////////
    ///		   Инициализация   		///
    ///////////////////////////////////

    // конструктор контракта
    // @param _ethFundWallet: адрес, куда будет выводиться эфир 
    // @param _reserveWallet: адрес, куда зачислятся резервные токены
    constructor(address _ethFundWallet, address _reserveWallet) public {
        // кошель для сбора средств не может быть нулевым
        require(_ethFundWallet != 0x0);
        require(_reserveWallet != 0x0);
        // создание контракта токена с первоначальной эмиссией резервных токенов
        token = new IcareumToken();
        // кошель для сбора средств в эфирах
        fundWallet = _ethFundWallet;
        // хранилище, средства из которого могут быть перемещены на основной кошель только после достижения softcap 
        vault = new RefundVault();
        // эмиссия резревных токенов
        _mintTokens(_reserveWallet,7000000);
    }
    // запуск продаж, изначально контракт находится в стадии эмиссии токенов этапа пресейла. После запуска эмиссия пресейла будет невозможна
    function startMainsale(uint256 _endBlock, uint256 _rateWeiFor10Cent) public
    onlyPresale 
    onlyOwner {
        // время конца продажи должно быть больше, чем время начала
        require(_endBlock > block.number);
        // курс эфира к доллару должен быть больше нуля
        require(_rateWeiFor10Cent > 0);
        // срок конца пресейла
        endBlock = _endBlock;
        // курс эфира к доллару
        rateWeiFor10Cent = _rateWeiFor10Cent;
        // старт 
        crowdsaleStarted = true;
        emit Started(); 
    }

    ///////////////////////////////////
    ///		Администрирование		///
    ///////////////////////////////////
    // Инвесторы
    // админ добавляет вручную приглашенного инвестора
    function addInvestor(address _addr) public 
	onlyAdmin {      
        isInvestor[_addr] = true;
    }
    function addReferral(address _addr, address _referrer) public 
    onlyAdmin {
        require(isInvestor[_referrer]);
        isInvestor[_addr] = true;
        referrerAddr[_addr] = _referrer;
    }
    // админ удаляет инвестора из списка
    function remInvestor(address _addr) public
    onlyAdmin {
        isInvestor[_addr] = false;
        referrerAddr[_addr] = 0x0;
    }

    // изменение фонодвого кошелька
    function changeFundWallet(address _fundWallet) public 
    onlyOwner {
        require(_fundWallet != 0x0);
        fundWallet = _fundWallet;
    }
    // изменение курса доллара к эфиру
    function changeRateWeiFor10Cent(uint256 _rate) public  
    onlyOwner {
        require(_rate > 0);
        rateWeiFor10Cent = _rate;
        emit RateChanged();
    }
    // эмиссия токенов, проданных на этапе пресейла. Допускает только эмиссию в рамках пресейл-капа
    // возможна только до начала основного сейла
    function mintPresaleTokens(address _beneficiary, uint256 _amount) public
    onlyPresale 
    onlyOwner {
        require(_beneficiary != 0x0);
        require(_amount > 0);
        presaleMintedTokens = presaleMintedTokens.add(_amount);
        require(presaleMintedTokens <= presaleTokenCap);
        _mintTokens(_beneficiary, _amount);
    }

    // эмиссия бонусных токенов. Возможна только после окончания основного сейла в рамках бонус-капа и до ручного завершения краудсейла владельцем
    function mintBonusTokens(address _beneficiary, uint256 _amount) public
    onlyBonusDistribution 
    onlyOwner {
        require(_beneficiary != 0x0);
        require(_amount > 0);
        bonusMintedTokens = bonusMintedTokens.add(_amount);
        require(bonusMintedTokens <= bonusTokenCap);
        _mintTokens(_beneficiary, _amount);
    }
    // успешное окончание сейла и запрет дальнейшей эмиссии. Возможно только после окончания сейла
    function finalizeCrowdsale() public 
    onlyBonusDistribution 
    onlyOwner {
        token.finishMinting();
        crowdsaleFinished = true;
        emit Finished();
    }
    // владелец разрешает возвраты если softcap не достигнут
    function allowRefunds() public
    onlyFailed 
    onlyOwner {
    	vault.enableRefunds();
    }
    // запрос владельем на выписку средств с хранилища если достигнут softcap
    function claimVaultFunds() public
    onlyOwner {

    	require(mainMintedTokens >= tokenSoftCap);
    	vault.close(fundWallet);
    }

    ///////////////////////////////////
    ///	  Операции для инвесторов   ///
    ///////////////////////////////////

    function () public payable {
        _preValidatePurchase(msg.sender,msg.value);

        uint256 tokensBought = _buyTokens(msg.sender,msg.value);

        if (referrerAddr[msg.sender] != 0x0)
    	   _addReferralBonus(referrerAddr[msg.sender],tokensBought);

    }
    // запрос на возврат средств инвестором, возможно только если цель не достигнута и после установки владельцем стадии возврата 
    function claimRefund() public 
    onlyFailed {
    	vault.refund(msg.sender);
    }

    ///////////////////////////////////
    ///   internal functions        ///
    ///////////////////////////////////  
     
    // функция покупки токенов инвестором
    function _buyTokens(address _buyer, uint256 _weiAmount) internal returns (uint256) {
        uint256 weiAmount = _weiAmount;
        uint256 tokenAmount = _calculateTokenAmount(weiAmount);
        //ограничение минимальной суммы покупки
        require(tokenAmount >= 100);
        uint256 tokensLeft = _tokensLeftOnStage();
        //возврат сдачи если токенов по текущей цене меньше 
        if (tokenAmount > tokensLeft) {
            uint256 sumToReturn = tokenAmount.sub(tokensLeft).mul(rateOfTokenInWei());
            tokenAmount = tokensLeft;
            weiAmount = weiAmount.sub(sumToReturn);
            _buyer.transfer(sumToReturn);
        }
        // увеличить общее количество эмитированных токенов
        mainMintedTokens = mainMintedTokens.add(tokenAmount);
        // обновление счетчика присланных денег (капитализации)
        weiRaised = weiRaised.add(weiAmount);
        // эмиссия токенов
        _mintTokens(_buyer,tokenAmount);

        emit TokenPurchase(_buyer, weiAmount, tokenAmount);
        // списание средств 
        _forwardFunds(_buyer,weiAmount);
        return tokenAmount;
    }
    function _addReferralBonus(address _beneficiary, uint256 _tokensBought) internal {
        uint256 tokensToAdd = _tokensBought.div(20);
        if (tokensToAdd > 0) {
            // увеличить общее количество эмитированных токенов
            mainMintedTokens = mainMintedTokens.add(tokensToAdd);
            // эмиссия токенов
            _mintTokens(_beneficiary,tokensToAdd);
        }
    }

    function _calculateTokenAmount(uint256 _weiAmount) view internal returns (uint256) {
        return _weiAmount.div(rateOfTokenInWei()); 
    }

    function _tokensLeftOnStage() view internal returns(uint256) {
        if (mainMintedTokens < mainsaleTokenCap1) return mainsaleTokenCap1.sub(mainMintedTokens);
        else if (mainMintedTokens < mainsaleTokenCap2) return mainsaleTokenCap2.sub(mainMintedTokens);
        else if (mainMintedTokens < mainsaleTokenCap3) return mainsaleTokenCap3.sub(mainMintedTokens);
        else if (mainMintedTokens < mainsaleTokenCap4) return mainsaleTokenCap4.sub(mainMintedTokens);
        else return 0;
    }
    // множитель стоимости токена относительно базы 0.1$
    function _tokenPriceMultiplier() view internal returns (uint256) {
        if (mainMintedTokens < mainsaleTokenCap1) return 3;
        else if(mainMintedTokens >= mainsaleTokenCap1 && mainMintedTokens < mainsaleTokenCap2) return 4;
        else if(mainMintedTokens >= mainsaleTokenCap2 && mainMintedTokens < mainsaleTokenCap3) return 5;
        else return 6;
    }

    // проверка возможности продажи токенов
    function _preValidatePurchase(address _beneficiary, uint256 _amount) view internal
    onlyMainsale 
    whenNotPaused {
        // продолжить только если адрес пользователя есть в списке приглашенных инвесторов
        require(isInvestor[_beneficiary]);
        // инвестор не может прислать нулевое количество эфира
        require(_amount != 0);
    }

    function _mintTokens(address _beneficiary, uint256 _amount) internal {
        token.mint(_beneficiary,_amount.mul(1e18));
    }

    // списание средств 
    function _forwardFunds(address _beneficiary, uint256 _amount) internal {
    	// если количество собранных средств меньше softcap - отправляем в vault 
    	if(mainMintedTokens < tokenSoftCap) vault.deposit.value(_amount)(_beneficiary);
    	// если собрано больше - отправляем сразу на фондовый кошелек
        else fundWallet.transfer(_amount);    	
    }

    // проверка на окончание продажи токенов
    function _mainsaleHasEnded() view internal returns (bool) {
    	if(!crowdsaleStarted) return false;
        return  block.number > endBlock || mainMintedTokens >= mainSaleTokenCap;
    }

}
