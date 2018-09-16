pragma solidity ^0.4.23;

// Copyright 2018 OpenST Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ----------------------------------------------------------------------------
// Auxiliary Chain: CoGateway Contract
//
// http://www.simpletoken.org/
//
// ----------------------------------------------------------------------------

import "./EIP20Interface.sol";
import "./MessageBus.sol";
import "./CoreInterface.sol";
import "./SafeMath.sol";
import "./Hasher.sol";
import "./ProofLib.sol";
import "./RLP.sol";
import "./UtilityTokenInterface.sol";
import "./ProtocolVersioned.sol";

/**
 * @title CoGateway Contract
 *
 * @notice CoGateway act as medium to send messages from auxiliary chain to
 *         origin chain. Currently CoGateway supports redeem and unstake,
 *         revert redeem message & linking of gateway and cogateway.
 */
contract CoGateway is Hasher {

	using SafeMath for uint256;

	/* Events */

    /** Emitted whenever a staking intent is confirmed. */
	event StakingIntentConfirmed(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		address _beneficiary,
		uint256 _amount,
		uint256 _blockHeight,
		bytes32 _hashLock
	);

    /** Emitted whenever a utility tokens are minted. */
	event ProgressedMint(
		bytes32 indexed _messageHash,
        address _staker,
		address _beneficiary,
        uint256 _stakeAmount,
        uint256 _mintedAmount,
		uint256 _rewardAmount,
        bytes32 _unlockSecret
	);

    /** Emitted whenever revert staking intent is confirmed. */
	event RevertStakingIntentConfirmed(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		uint256 _amount
	);

    /** Emitted whenever redemption is initiated. */
	event RedemptionIntentDeclared(
		bytes32 indexed _messageHash,
        address _redeemer,
        uint256 _redeemerNonce,
        address _beneficiary,
        uint256 _amount
	);

    /** Emitted whenever redemption is completed. */
	event ProgressedRedemption(
		bytes32 indexed _messageHash,
        address _redeemer,
        uint256 _redeemerNonce,
		uint256 _amount,
        bytes32 _unlockSecret
	);

    /** Emitted whenever revert redemption is initiated. */
	event RevertRedemptionDeclared(
		bytes32 indexed _messageHash,
		address _redeemer,
		uint256 _redeemerNonce,
		uint256 _amount
	);

    /** Emitted whenever revert redemption is reverted. */
	event RevertedRedemption(
        bytes32 indexed _messageHash,
		address _redeemer,
        uint256 _redeemerNonce,
		uint256 _amount
	);

    /** Emitted whenever a gateway and coGateway linking is confirmed. */
	event GatewayLinkConfirmed(
		bytes32 indexed _messageHash,
		address _gateway,
		address _cogateway,
		address _valueToken,
        address _utilityToken
	);

    /** Emitted whenever a gateway and coGateway linking is complete. */
	event GatewayLinkProgressed(
		bytes32 indexed _messageHash,
		address _gateway,
		address _cogateway,
        address _valueToken,
        address _utilityToken,
        bytes32 _unlockSecret
	);

    /** Emitted whenever a Gateway contract is proven.
     *	wasAlreadyProved parameter differentiates between first call and replay
     *  call of proveGateway method for same block height
     */
	event GatewayProven(
        address _gateway,
		uint256 _blockHeight,
		bytes32 _storageRoot,
		bool _wasAlreadyProved
	);

	/* Struct */

    /**
	 * Redeem stores the redemption information about the redeem amount,
	 * beneficiary address, message data and facilitator address.
	 */
	struct Redeem {

        /** Amount that will be redeemed. */
		uint256 amount;

        /**
		 * Address where the value tokens will be unstaked in the
		 * origin chain.
		 */
		address beneficiary;

        /** Message data. */
		MessageBus.Message message;

        /** Address of the facilitator that initiates the staking process. */
		address facilitator;
	}

    /**
	 * Mint stores the minting information
	 * like mint amount, beneficiary address, message data.
	 */
	struct Mint {

        /** Amount that will be minted. */
		uint256 amount;

        /** Address for which the utility tokens will be minted */
		address beneficiary;

        /** Message data. */
		MessageBus.Message message;
	}

    /**
	 * GatewayLink stores data for linking of Gateway and CoGateway.
	 */
	struct GatewayLink {

        /**
		 * message hash is the sha3 of gateway address, cogateway address,
		 * bounty, token name, token symbol, token decimals , _nonce, token
		 */
		bytes32 messageHash;

        /** Message data. */
		MessageBus.Message message;
	}

    /* constants */

    uint8 MESSAGE_BOX_OFFSET = 1;

    /* public variables */

    /** Gateway contract address. */
    address public gateway;

    /**
     * Message box.
     * @dev keep this is at location 1, in case this is changed then update
     *      constant OUTBOX_OFFSET accordingly.
     */
    MessageBus.MessageBox messageBox;

    /** Specifies if the Gateway and CoGateway contracts are linked. */
    bool public linked;

    /** Specifies if the CoGateway is deactivated for any new redeem process.*/
    bool public deactivated;

    /** Organisation address. */
    address public organisation;

    /** amount of base token which is staked by facilitator. */
    uint256 public bounty;

    /** address of utility token. */
    address public utilityToken;

    /** address of value token. */
    address public valueToken;

    /** address of core contract. */
    CoreInterface public core;

    /** Maps messageHash to the Mint object. */
    mapping(bytes32 /*messageHash*/ => Mint) mints;

    /** Maps messageHash to the Redeem object. */
    mapping(bytes32/*messageHash*/ => Redeem) redeems;

    /**
     * Maps address to messageHash.
     *
     * Once the minting or redeem process is started the corresponding
     * message hash is stored against the staker/redeemer address. This is used
     * to restrict simultaneous/multiple minting and redeem for a particular
     * address. This is also used to determine the nonce of the particular
     * address. Refer getNonce for the details.
     */
    mapping(address /*address*/ => bytes32 /*messageHash*/) activeProcess;

    /** Maps blockHeight to storageRoot*/
	mapping(uint256 /* block height */ => bytes32) private storageRoots;

    /* private variables */

    /** Gateway link. */
    GatewayLink gatewayLink;

    /* path to prove merkle account proof for Gateway contract */
	bytes private encodedGatewayPath;

    /* modifiers */

    /** checks that only organisation can call a particular function. */
    modifier onlyOrganisation() {
        require(
            msg.sender == organisation,
            "Only organisation can call the function"
        );
        _;
    }

    /** checks that contract is linked and is not deactivated */
    modifier isActive() {
        require(
            deactivated == false && linked == true,
            "Contract is restricted to use"
        );
        _;
    }

    /* Constructor */

    /**
     * @notice Initialise the contract by providing the Gateway contract
     *         address for which the CoGateway will enable facilitation of
     *         minting and redeeming.
     *
     * @param _valueToken The value token contract address.
     * @param _utilityToken The utility token address that will be used for
     *                      minting the utility token.
     * @param _core Core contract address.
     * @param _bounty The amount that facilitator will stakes to initiate the
     *                staking process.
     * @param _organisation Organisation address.
     * @param _gateway Gateway contract address.
     */
	constructor(
		address _valueToken,
		address _utilityToken,
		CoreInterface _core,
		uint256 _bounty,
		address _organisation,
		address _gateway
	)
	public
	{
		require(
            _valueToken != address(0),
            "Value token address must not be zero"
        );
		require(
            _utilityToken != address(0),
            "Utility token address must not be zero"
        );
        require(
            _core != address(0),
            "Core contract address must not be zero"
        );
        require(
            _organisation != address(0),
            "Organisation address must not be zero"
        );
		require(
            _gateway != address(0),
            "Gateway address must not be zero"
        );

        //gateway and cogateway is not linked yet so it is initialized as false
		linked = false;

        // gateway is active
		deactivated = false;

		valueToken = _valueToken;
		utilityToken = _utilityToken;
		gateway = _gateway;
		core = _core;
		bounty = _bounty;
		organisation = _organisation;

        // update the encodedGatewayPath
		encodedGatewayPath = ProofLib.bytes32ToBytes(
            keccak256(abi.encodePacked(_gateway))
        );
	}

    /* External functions */

    /**
     * @notice Confirm the Gateway and CoGateway contracts initiation.
     *
     * @param _intentHash Gateway and CoGateway linking intent hash.
     *                    This is a sha3 of gateway address, cogateway address,
     *                    bounty, token name, token symbol, token decimals,
     *                    _nonce, token.
     * @param _nonce Nonce of the sender. Here in this case its organisation
     *               address of Gateway
     * @param _sender The address that signs the message hash. In this case it
     *                has to be organisation address of Gateway
     * @param _hashLock Hash lock, set by the facilitator.
     * @param _blockHeight Block number for which the proof is valid
     * @param _rlpParentNodes RLP encoded parent node data to prove in
	 *                        messageBox outbox of Gateway
	 *
     * @return messageHash_ Message hash
     */
    function confirmGatewayLinkIntent(
		bytes32 _intentHash,
		uint256 _nonce,
		address _sender,
		bytes32 _hashLock,
		uint256 _blockHeight,
		bytes memory _rlpParentNodes
	)
	    public // TODO: check to change it to external, getting stack to deep.
        returns(bytes32 messageHash_)
	{
		require(
            linked == false,
            "CoGateway contract must not be already linked"
        );
        require(
            deactivated == false,
            "Gateway contract must not be deactivated"
        );
		require(
            gatewayLink.messageHash == bytes32(0),
            "Linking is already initiated"
        );
		require(
            _nonce == _getNonce(_sender),
            "Sender nonce must be in sync"
        );

        bytes32 storageRoot = storageRoots[_blockHeight];
        require(
            storageRoot != bytes32(0),
            "Storage root for given block height must not be zero"
        );

        // TODO: need to add check for MessageBus.
        //       (This is already done in other branch)
		bytes32 intentHash = hashLinkGateway(
			gateway,
			address(this),
			bounty,
			EIP20Interface(utilityToken).name(),
			EIP20Interface(utilityToken).symbol(),
			EIP20Interface(utilityToken).decimals(),
			_nonce,
			valueToken);

        // Ensure that the _intentHash matches the calculated intentHash
		require(
            intentHash == _intentHash,
            "Incorrect intent hash"
        );

        // Get the message hash
		messageHash_ = MessageBus.messageDigest(
            GATEWAY_LINK_TYPEHASH,
            intentHash,
            _nonce,
            0
        );

        //TODO: Check when its deleted
        // update the gatewayLink storage
		gatewayLink = GatewayLink ({
			messageHash: messageHash_,
			message: getMessage(
				_sender,
				_nonce,
				0,
				0,
				_intentHash,
				_hashLock
				)
			});

        // Declare message in inbox
		MessageBus.confirmMessage(
			messageBox,
			GATEWAY_LINK_TYPEHASH,
			gatewayLink.message,
			_rlpParentNodes,
            MESSAGE_BOX_OFFSET,
            storageRoot
        );

        // Emit GatewayLinkConfirmed event
		emit GatewayLinkConfirmed(
			messageHash_,
			gateway,
			address(this),
			valueToken,
            utilityToken
		);
	}

    /**
     * @notice Complete the Gateway and CoGateway contracts linking. This will
     *         set the variable linked to true, and thus it will activate the
     *         CoGateway contract for mint and redeem.
     *
     * @param _messageHash Message hash
     * @param _unlockSecret Unlock secret for the hashLock provide by the
     *                      facilitator while initiating the Gateway/CoGateway
     *                      linking
     *
     * @return `true` if gateway linking was successfully progressed
     */
    function progressGatewayLink(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
	    external
	    returns (bool)
	{
		require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
		require(
            _unlockSecret != bytes32(0),
            "Unlock secret must not be zero"
        );
		require(
            gatewayLink.messageHash == _messageHash,
            "Invalid message hash"
        );

        // Progress inbox
		MessageBus.progressInbox(
            messageBox,
            GATEWAY_LINK_TYPEHASH,
            gatewayLink.message,
            _unlockSecret
        );

        // Update to specify the Gateway/CoGateway is linked
		linked = true;

        // Emit GatewayLinkProgressed event
		emit GatewayLinkProgressed(
			_messageHash,
			gateway,
			address(this),
            valueToken,
			utilityToken,
            _unlockSecret
		);

		return true;
	}

    /**
	 * @notice Confirms the initiation of the stake process.
	 *
	 * @param _staker Staker address.
	 * @param _stakerNonce Nonce of the staker address.
	 * @param _beneficiary The address in the auxiliary chain where the utility
	 *                     tokens will be minted.
	 * @param _amount Amount of utility token will be minted.
	 * @param _gasPrice Gas price that staker is ready to pay to get the stake
	 *                  and mint process done
	 * @param _gasLimit Gas limit that staker is ready to pay
	 * @param _hashLock Hash Lock provided by the facilitator.
	 * @param _blockHeight Block number for which the proof is valid
     * @param _rlpParentNodes RLP encoded parent node data to prove in
	 *                        messageBox outbox of Gateway
	 *
	 * @return messageHash_ which is unique for each request.
	 */
	function confirmStakingIntent(
		address _staker,
		uint256 _stakerNonce,
		address _beneficiary,
		uint256 _amount,
		uint256 _gasPrice,
		uint256 _gasLimit,
		bytes32 _hashLock,
        uint256 _blockHeight,
        bytes memory _rlpParentNodes
	)
	    public
	    returns (bytes32 messageHash_)
	{
        // Get the initial gas amount
		uint256 initialGas = gasleft();

		require(
            _staker != address(0),
            "Staker address must not be zero"
        );
		require(
            _beneficiary != address(0),
            "Beneficiary address must not be zero"
        );
		require(
            _amount != 0,
            "Mint amount must not be zero"
        );
		require(
            _gasPrice != 0,
            "Gas price must not be zero"
        );
        require(
            _gasLimit != 0,
            "Gas limit must not be zero"
        );
        //TODO: block height zero should be allowed, please discuss this.
		require(
            _blockHeight != 0,
            "Block height must not be zero"
        );
		require(
            _hashLock != bytes32(0),
            "Hash lock must not be zero"
        );
		require(
            _rlpParentNodes.length != 0,
            "RLP parent nodes must not be zero"
        );

        // Get the staking intent hash
		bytes32 intentHash = hashStakingIntent(
            _amount,
            _beneficiary,
            _staker,
            _gasPrice,
            valueToken
        );

        // Get the messageHash
		messageHash_ = MessageBus.messageDigest(
            STAKE_TYPEHASH,
            intentHash,
            _stakerNonce,
            _gasPrice
        );

        // Get previousMessageHash
		bytes32 previousMessageHash = initiateNewInboxProcess(
            _staker,
            _stakerNonce,
            messageHash_
        );

        // Delete the previous progressed / revoked mint data
		delete mints[previousMessageHash];

		mints[messageHash_] = getMint(
            _amount,
			_beneficiary,
			_staker,
			_stakerNonce,
			_gasPrice,
			_gasLimit,
			intentHash,
			_hashLock
		);

        // execute the confirm staking intent. This is done in separate
        // function to avoid stack too deep error
		executeConfirmStakingIntent(
            mints[messageHash_].message,
            _blockHeight,
            _rlpParentNodes
        );

        // Emit StakingIntentConfirmed event
		emit StakingIntentConfirmed(
			messageHash_,
			_staker,
			_stakerNonce,
			_beneficiary,
			_amount,
			_blockHeight,
			_hashLock
		);

        // Update the gas consumed for this function.
		mints[messageHash_].message.gasConsumed = initialGas.sub(gasleft());
	}

    /**
	 * @notice Complete minting process by minting the utility tokens
	 *
	 * @param _messageHash Message hash.
	 * @param _unlockSecret Unlock secret for the hashLock provide by the
 	 *                      facilitator while initiating the stake
 	 *
 	 * @return staker_ Staker address
 	 * @return beneficiary_ Address to which the utility tokens will be
 	 *                      transferred after minting
 	 * @return stakeAmount_ Total amount for which the staking was
 	 *                      initiated. The reward amount is deducted from the
 	 *                      this amount and is given to the facilitator.
 	 * @return mintedAmount_ Actual minted amount, after deducting the reward
 	 *                       from the total (stake) amount.
 	 * @return rewardAmount_ Reward amount that is transferred to facilitator
	 */
	function progressMinting(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
	    external
	    returns (
            address staker_,
            address beneficiary_,
		    uint256 stakeAmount_,
		    uint256 mintedAmount_,
		    uint256 rewardAmount_
	    )
	{
        // Get the initial gas amount
		uint256 initialGas = gasleft();

		require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
		require(
            _unlockSecret != bytes32(0),
            "Unlock secret must not be zero"
        );

		Mint storage mint = mints[_messageHash];
		MessageBus.Message storage message = mint.message;

        // Progress inbox
		MessageBus.progressInbox(
            messageBox,
            STAKE_TYPEHASH,
            mint.message,
            _unlockSecret
        );

        staker_ = message.sender;
        beneficiary_ = mint.beneficiary;
        stakeAmount_ = mint.amount;

		rewardAmount_ = MessageBus.feeAmount(
            message,
            initialGas,
            50000  //21000 * 2 for transactions + approx buffer
        );

		mintedAmount_ = stakeAmount_.sub(rewardAmount_);

		//Mint token after subtracting reward amount
        UtilityTokenInterface(utilityToken).mint(beneficiary_, mintedAmount_);

		//reward beneficiary with the reward amount
        UtilityTokenInterface(utilityToken).mint(msg.sender, rewardAmount_);

        // Emit ProgressedMint event
		emit ProgressedMint(
			_messageHash,
            message.sender,
            mint.beneficiary,
            stakeAmount_,
            mintedAmount_,
			rewardAmount_,
            _unlockSecret
		);
	}

    /**
	 * @notice Completes the minting process by providing the merkle proof
	 *         instead of unlockSecret. In case the facilitator process is not
	 *         able to complete the stake and minting process then this is an
	 *         alternative approach to complete the process
	 *
	 * @dev This can be called to prove that the outbox status of messageBox on
	 *      Gateway is either declared or progressed.
	 *
	 * @param _messageHash Message hash.
	 * @param _rlpEncodedParentNodes RLP encoded parent node data to prove in
	 *                               messageBox inbox of Gateway
	 * @param _blockHeight Block number for which the proof is valid
	 * @param _messageStatus Message status i.e. Declared or Progressed that
	 *                       will be proved.
	 *
	 * @return stakeAmount_ Total amount for which the stake was initiated. The
	 *                      reward amount is deducted from the total amount and
	 *                      is given to the facilitator.
 	 * @return mintedAmount_ Actual minted amount, after deducting the reward
 	 *                        from the total amount.
 	 * @return rewardAmount_ Reward amount that is transferred to facilitator
	 */
	function progressMintingWithProof(
		bytes32 _messageHash,
		bytes _rlpEncodedParentNodes,
		uint256 _blockHeight,
		uint256 _messageStatus
	)
	    public
	    returns (
		    uint256 stakeAmount_,
		    uint256 mintedAmount_,
		    uint256 rewardAmount_
	    )
	{
        // Get the inital gas
		uint256 initialGas = gasleft();

        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
		require(
            _rlpEncodedParentNodes.length > 0,
            "RLP encoded parent nodes must not be zero"
        );

        // Get the storage root for the given block height
		bytes32 storageRoot = storageRoots[_blockHeight];
		require(
            storageRoot != bytes32(0),
            "Storage root must not be zero"
        );

		Mint storage mint = mints[_messageHash];
		MessageBus.Message storage message = mint.message;

		MessageBus.progressInboxWithProof(messageBox,
			STAKE_TYPEHASH,
			mint.message,
			_rlpEncodedParentNodes,
            MESSAGE_BOX_OFFSET,
			storageRoot,
			MessageBus.MessageStatus(_messageStatus));

        stakeAmount_ = mint.amount;

		//TODO: Remove the hardcoded 50000. Discuss and implement it properly
        //21000 * 2 for transactions + approx buffer
		rewardAmount_ = MessageBus.feeAmount(
            message,
            initialGas,
            50000
        );

		mintedAmount_ = stakeAmount_.sub(rewardAmount_);

		//Mint token after subtracting reward amount
        UtilityTokenInterface(utilityToken).mint(mint.beneficiary, mintedAmount_);

		//reward beneficiary with the reward amount
        UtilityTokenInterface(utilityToken).mint(msg.sender, rewardAmount_);

        //TODO: we can have a seperate event for this.
        // Emit ProgressedMint event
		emit ProgressedMint(
            _messageHash,
            message.sender,
            mint.beneficiary,
            stakeAmount_,
            mintedAmount_,
            rewardAmount_,
            bytes32(0)
        );
	}

    /**
	 * @notice Declare staking revert intent
	 *
	 * @param _messageHash Message hash.
	 * @param _blockHeight Block number for which the proof is valid
	 * @param _rlpEncodedParentNodes RLP encoded parent node data to prove
	 *                               DeclaredRevocation in messageBox outbox
	 *                               of Gateway
	 *
	 * @return staker_ Staker address
	 * @return stakerNonce_ Staker nonce
	 * @return amount_ Redeem amount
	 */
	function confirmRevertStakingIntent(
		bytes32 _messageHash,
		uint256 _blockHeight,
		bytes _rlpEncodedParentNodes
	)
	    external
	    returns (
            address staker_,
            uint256 stakerNonce_,
            uint256 amount_
        )
	{
        // Get the initial gas value
		uint256 initialGas = gasleft();

        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
        require(
            _rlpEncodedParentNodes.length > 0,
            "RLP encoded parent nodes must not be zero"
        );

		Mint storage mint = mints[_messageHash];

        MessageBus.Message storage message = mint.message;
        require(
            message.intentHash != bytes32(0),
            "RevertRedemption intent hash must not be zero"
        );

        // Get the storage root
		bytes32 storageRoot = storageRoots[_blockHeight];
        require(
            storageRoot != bytes32(0),
            "Storage root must not be zero"
        );

        // Confirm revocation
        MessageBus.confirmRevocation(
            messageBox,
            STAKE_TYPEHASH,
            message,
            _rlpEncodedParentNodes,
            MESSAGE_BOX_OFFSET,
            storageRoot
        );

        staker_ = message.sender;
        stakerNonce_ = message.nonce;
        amount_ = mint.amount;

        // Emit RevertStakingIntentConfirmed event
		emit RevertStakingIntentConfirmed(
			_messageHash,
			message.sender,
			message.nonce,
            mint.amount
		);

        // Update the gas consumed for this function.
		message.gasConsumed = initialGas.sub(gasleft());
	}

    /**
	 * @notice Initiates the redemption process.
	 *
	 * @dev In order to redeem the redeemer needs to approve CoGateway contract
	 *      for redeem amount. Redeem amount is transferred from redeemer
	 *      address to CoGateway contract.
	 *      This is a payable function. The bounty is transferred in base token
	 *      Redeemer is always msg.sender
	 *
	 * @param _amount Redeem amount that will be transferred form redeemer
	 *                account.
	 * @param _beneficiary The address in the origin chain where the value
	 *                     tok ens will be released.
	 * @param _facilitator Facilitator address.
	 * @param _gasPrice Gas price that redeemer is ready to pay to get the
	 *                  redemption process done.
	 * @param _gasLimit Gas limit that redeemer is ready to pay
	 * @param _nonce Nonce of the redeemer address.
	 * @param _hashLock Hash Lock provided by the facilitator.
	 *
	 * @return messageHash_ which is unique for each request.
	 */
	function redeem(
		uint256 _amount,
		address _beneficiary,
		address _facilitator,
		uint256 _gasPrice,
		uint256 _gasLimit,
		uint256 _nonce,
		bytes32 _hashLock
	)
	    public
	    payable
	    isActive
	    returns (bytes32 messageHash_)
	{
		require(
            msg.value == bounty,
            "msg.value must match the bounty amount"
        );
		require(
            _amount > uint256(0),
            "Redeem amount must not be zero"
        );

        //TODO: This check will be removed so that tokens can be burnt.
        //      Discuss and verify all the cases
		require(
            _beneficiary != address(0),
            "Beneficiary address must not be zero"
        );
		require(
            _facilitator != address(0),
            "Facilitator address must not be zero"
        );
        require(
            _gasPrice != 0,
            "Gas price must not be zero"
        );
        require(
            _gasLimit != 0,
            "Gas limit must not be zero"
        );

        //TODO: Do we need this check ?
		require(
            _hashLock != bytes32(0),
            "HashLock must not be zero"
        );

        //TODO: include _gasLimit in redemption hash
        // Get the redemption intent hash
		bytes32 intentHash = hashRedemptionIntent(
            _amount,
            _beneficiary,
            msg.sender,
            _gasPrice,
            valueToken
        );

        // Get the messageHash
		messageHash_ = MessageBus.messageDigest(
            REDEEM_TYPEHASH,
            intentHash,
            _nonce,
            _gasPrice
        );

        // Get previousMessageHash
		bytes32 previousMessageHash = initiateNewOutboxProcess(
            msg.sender,
            _nonce,
            messageHash_
        );

        // Delete the previous progressed/revoked redeem data
		delete redeems[previousMessageHash];

		redeems[messageHash_] = Redeem({
			amount : _amount,
			beneficiary : _beneficiary,
            facilitator : _facilitator,
			message : getMessage(
                msg.sender,
                _nonce,
                _gasPrice,
                _gasLimit,
                intentHash,
                _hashLock)
			});

		//TODO: Move this code in MessageBus.
		require(
            messageBox.outbox[messageHash_] ==
            MessageBus.MessageStatus.Undeclared,
            "Message status must be Undeclared"
        );
        // Update the message outbox status to declared.
		messageBox.outbox[messageHash_] = MessageBus.MessageStatus.Declared;

		//transfer redeem amount to Co-Gateway
        EIP20Interface(utilityToken).transferFrom(
            msg.sender,
            address(this),
            _amount
        );

        // Emit RedemptionIntentDeclared event
		emit RedemptionIntentDeclared(
			messageHash_,
            msg.sender,
            _nonce,
			_beneficiary,
            _amount
		);
	}

    /**
	 * @notice Completes the redemption process.
	 *
	 * @param _messageHash Message hash.
	 * @param _unlockSecret Unlock secret for the hashLock provide by the
 	 *                      facilitator while initiating the redeem
 	 *
 	 * @return redeemer_ Redeemer address
 	 * @return redeemAmount_ Redeem amount
	 */
	function progressRedemption(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
	    external
	    returns (
            address redeemer_,
            uint256 redeemAmount_
        )
	{
        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
        //TODO: unlock secret can be zero. Discuss if this check is needed.
        require(
            _unlockSecret != bytes32(0),
            "Unlock secret must not be zero"
        );

        // Get the message object
		MessageBus.Message storage message = redeems[_messageHash].message;

        // Get the redeemer address
        redeemer_ = message.sender;

        // Get the redeem amount
        redeemAmount_ = redeems[_messageHash].amount;

        // Progress outbox
		MessageBus.progressOutbox(
            messageBox,
            REDEEM_TYPEHASH,
            message,
            _unlockSecret
        );

        // burn the redeem amount
        UtilityTokenInterface(utilityToken).burn(address(this), redeemAmount_);

        // Transfer the bounty amount to the facilitator
		msg.sender.transfer(bounty);

        // Emit ProgressedRedemption event.
		emit ProgressedRedemption(
			_messageHash,
            message.sender,
            message.nonce,
            redeemAmount_,
            _unlockSecret
		);
	}

    /**
     * @notice Completes the redemption process by providing the merkle proof
     *         instead of unlockSecret. In case the facilitator process is not
     *         able to complete the redeem and unstake process then this is an
     *         alternative approach to complete the process
     *
     * @dev This can be called to prove that the inbox status of messageBox on
     *      Gateway is either declared or progressed.
     *
     * @param _messageHash Message hash.
     * @param _rlpEncodedParentNodes RLP encoded parent node data to prove in
     *                               messageBox outbox of Gateway
     * @param _blockHeight Block number for which the proof is valid
     * @param _messageStatus Message status i.e. Declared or Progressed that
     *                       will be proved.
     *
     * @return redeemer_ Redeemer address
     * @return redeemAmount_ Redeem amount
     */
	function progressRedemptionWithProof(
		bytes32 _messageHash,
		bytes _rlpEncodedParentNodes,
		uint256 _blockHeight,
		uint256 _messageStatus
	)
	    external
	    returns (
            address redeemer_,
            uint256 redeemAmount_
        )
	{
        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
        require(
            _rlpEncodedParentNodes.length > 0,
            "RLP encoded parent nodes must not be zero"
        );

		bytes32 storageRoot = storageRoots[_blockHeight];

        require(
            storageRoot != bytes32(0),
            "Storage root must not be zero"
        );

        MessageBus.Message storage message = redeems[_messageHash].message;

        redeemer_ = message.sender;
        redeemAmount_ = redeems[_messageHash].amount;

		MessageBus.progressOutboxWithProof(
			messageBox,
			REDEEM_TYPEHASH,
            message,
			_rlpEncodedParentNodes,
            MESSAGE_BOX_OFFSET,
			storageRoot,
			MessageBus.MessageStatus(_messageStatus)
		);

        // Burn the redeem amount.
        UtilityTokenInterface(utilityToken).burn(address(this), redeemAmount_);

        // Transfer the bounty amount to the facilitator
        msg.sender.transfer(bounty);

        //TODO: we can have a seperate event for this.
        // Emit ProgressedRedemption event.
		emit ProgressedRedemption(
            _messageHash,
            redeemer_,
            message.nonce,
            redeemAmount_,
            bytes32(0)
        );
	}

    /**
	 * @notice Revert redemption to stop the redeem process
	 *
	 * @param _messageHash Message hash.
	 *
	 * @return redeemer_ Redeemer address
	 * @return redeemerNonce_ Redeemer nonce
	 * @return amount_ Redeem amount
	 */
	function revertRedemption(
		bytes32 _messageHash
	)
	    external
	    returns (
		    address redeemer_,
		    uint256 redeemerNonce_,
		    uint256 amount_
	    )
	{
        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );

        // get the message object for the _messageHash
		MessageBus.Message storage message = redeems[_messageHash].message;

		require(message.intentHash != bytes32(0));

        require(
            message.intentHash != bytes32(0),
            "RedemptionIntentHash must not be zero"
        );

        require(
            message.sender == msg.sender,
            "msg.sender must match"
        );

        //TODO: Move this code in MessageBus.
        require(
            messageBox.outbox[_messageHash] ==
            MessageBus.MessageStatus.Undeclared,
            "Message status must be Undeclared"
        );
        // Update the message outbox status to declared.
        messageBox.outbox[_messageHash] = MessageBus.MessageStatus.Declared;

		redeemer_ = message.sender;
        redeemerNonce_ = message.nonce;
        amount_ = redeems[_messageHash].amount;

        // Emit RevertRedemptionDeclared event.
		emit RevertRedemptionDeclared(
            _messageHash,
            redeemer_,
            redeemerNonce_,
            amount_
        );
	}

    /**
	 * @notice Complete revert redemption by providing the merkle proof
	 *
	 * @param _messageHash Message hash.
	 * @param _blockHeight Block number for which the proof is valid
	 * @param _rlpEncodedParentNodes RLP encoded parent node data to prove
	 *                               DeclaredRevocation in messageBox inbox
	 *                               of Gateway
	 * @param _messageStatus Message status in CoGateway for given messageHash.
	 *
	 * @return redeemer_ Redeemer address
	 * @return redeemerNonce_ Redeemer nonce
	 * @return amount_ Redeem amount
	 */
	function progressRevertRedemption(
		bytes32 _messageHash,
		uint256 _blockHeight,
		bytes _rlpEncodedParentNodes,
        uint256 _messageStatus
	)
	    external
	    returns (
            address redeemer_,
            uint256 redeemerNonce_,
            uint256 amount_
        )
	{
        require(
            _messageHash != bytes32(0),
            "Message hash must not be zero"
        );
        require(
            _rlpEncodedParentNodes.length > 0,
            "RLP encoded parent nodes must not be zero"
        );

        // Get the message object
		MessageBus.Message storage message = redeems[_messageHash].message;
        require(
            message.intentHash != bytes32(0),
            "StakingIntentHash must not be zero"
        );

        // Get the storageRoot for the given block height
		bytes32 storageRoot = storageRoots[_blockHeight];
        require(
            storageRoot != bytes32(0),
            "Storage root must not be zero"
        );

        // Progress with revocation message
        MessageBus.progressOutboxRevocation(
            messageBox,
            message,
            REDEEM_TYPEHASH,
            MESSAGE_BOX_OFFSET,
            _rlpEncodedParentNodes,
            storageRoot,
            MessageBus.MessageStatus(_messageStatus)
        );

		Redeem storage redeemData = redeems[_messageHash];

        redeemer_ = message.sender;
        redeemerNonce_ = message.nonce;
        amount_ = redeemData.amount;

        // return the redeem amount back
        EIP20Interface(utilityToken).transfer(message.sender, amount_);

        // transfer the bounty to msg.sender
		msg.sender.transfer(bounty);

        // Emit RevertedRedemption event
		emit RevertedRedemption(
            _messageHash,
			message.sender,
            message.nonce,
			redeemData.amount
        );
	}

	/**
     *  @notice External function prove gateway.
     *
     *  @dev proveGateway can be called by anyone to verify merkle proof of
     *       gateway contract address. Trust factor is brought by stateRoots
     *       mapping. stateRoot is committed in commitStateRoot function by
     *       mosaic process which is a trusted decentralized system running
     *       separately. It's important to note that in replay calls of
     *       proveGateway bytes _rlpParentNodes variable is not validated. In
     *       this case input storage root derived from merkle proof account
     *       nodes is verified with stored storage root of given blockHeight.
     *		 GatewayProven event has parameter wasAlreadyProved to
     *       differentiate between first call and replay calls.
     *
     *  @param _blockHeight Block height at which Gateway is to be proven.
     *  @param _rlpEncodedAccount RLP encoded account node object.
     *  @param _rlpParentNodes RLP encoded value of account proof parent nodes.
     *
     *  @return `true` if Gateway account is proved
     */
	function proveGateway(
		uint256 _blockHeight,
		bytes _rlpEncodedAccount,
		bytes _rlpParentNodes
    )
	    external
	    returns (bool /* success */)
	{
		// _rlpEncodedAccount should be valid
		require(
            _rlpEncodedAccount.length != 0,
            "Length of RLP encoded account is 0"
        );

		// _rlpParentNodes should be valid
		require(
            _rlpParentNodes.length != 0,
            "Length of RLP parent nodes is 0"
        );

		bytes32 stateRoot = core.getStateRoot(_blockHeight);

        // State root should be present for the block height
		require(
            stateRoot != bytes32(0),
            "State root must not be zero"
        );

		// If account already proven for block height
		bytes32 provenStorageRoot = storageRoots[_blockHeight];

		if (provenStorageRoot != bytes32(0)) {

			// Check extracted storage root is matching with existing stored
            // storage root
			require(
                provenStorageRoot == storageRoot,
                "Storage root mismatch when account is already proven"
            );

			// wasAlreadyProved is true here since proveOpenST is replay call
            // for same block height
			emit GatewayProven(
                gateway,
                _blockHeight,
                storageRoot,
                true
            );

			// return true
			return true;
		}

		bytes32 storageRoot = ProofLib.proveAccount(
            _rlpEncodedAccount,
            _rlpParentNodes,
            encodedGatewayPath,
            stateRoot
        );

		storageRoots[_blockHeight] = storageRoot;

        // wasAlreadyProved is false since Gateway is called for the first time
        // for a block height
		emit GatewayProven(
            gateway,
            _blockHeight,
            storageRoot,
            false
        );

		return true;
	}

    /**
     * @notice Activate or Deactivate CoGateway contract. Can be set only by the
     *         Organisation address
     *
     * @param _active Boolean specify to activate or deactivate
     *
     * @return `true` if value is set
     */
    function setCoGatewayActive(bool _active)
        external
        onlyOrganisation
        returns (bool)
    {
        require(
            deactivated == _active,
            "Value is already set"
        );
        deactivated = !_active;
        return true;
    }

    /**
	 * @notice Get the nonce for the given account address
	 *
	 * @param _account Account address for which the nonce is to fetched
	 *
	 * @return nonce
	 */
    function getNonce(address _account)
        external
        view
        returns (uint256 /* nonce */)
    {
        // call the private method
        return _getNonce(_account);
    }


    /* private methods */

    /**
	 * @notice private function to execute confirm staking intent.
	 *
	 * @dev This function is to avoid stack too deep error in
	 *      confirmStakingIntent function
	 *
	 * @param _message message object
	 * @param _blockHeight Block number for which the proof is valid
	 * @param _rlpParentNodes RLP encoded parent nodes.
	 *
	 * @return `true` if executed successfully
	 */
	function executeConfirmStakingIntent(
		MessageBus.Message storage _message,
		uint256 _blockHeight,
		bytes _rlpParentNodes
	)
	    private
        returns (bool)
	{
        // Get storage root
		bytes32 storageRoot = storageRoots[_blockHeight];
        require(
            storageRoot != bytes32(0),
            "Storage root must not be zero"
        );

        // Confirm message
		MessageBus.confirmMessage(
			messageBox,
			STAKE_TYPEHASH,
			_message,
			_rlpParentNodes,
            MESSAGE_BOX_OFFSET,
            storageRoot
        );

        return true;
	}

    //TODO: this will move to base class
    /**
     * @notice Clears the previous outbox process. Validates the
     *         nonce. Updates the process with current messageHash
     *
     * @param _account Account address
     * @param _nonce Nonce for the account address
     * @param _messageHash Message hash
     *
     * @return previousMessageHash_ previous messageHash
     */
    function initiateNewOutboxProcess(
        address _account,
        uint256 _nonce,
        bytes32 _messageHash
    )
        private
        returns (bytes32 previousMessageHash_)
    {
        require(
            _nonce == _getNonce(_account),
            "Invalid nonce"
        );

        previousMessageHash_ = activeProcess[_account];

        if (previousMessageHash_ != bytes32(0)) {

            require(
                messageBox.outbox[previousMessageHash_] !=
                MessageBus.MessageStatus.Progressed
                ||
                messageBox.outbox[previousMessageHash_] !=
                MessageBus.MessageStatus.Revoked,
                "Prevous process is not completed"
            );
            //TODO: Commenting below line. Please check if deleting this will
            //      effect any process related to merkle proof in other chain.
            //delete messageBox.outbox[previousMessageHash_];
        }

        // Update the active proccess.
        activeProcess[_account] = _messageHash;
    }

    //TODO: this will move to base class
    /**
     * @notice Clears the previous inbox process. Validates the
     *         nonce. Updates the process with current messageHash
     *
     * @param _account Account address
     * @param _nonce Nonce for the account address
     * @param _messageHash Message hash
     *
     * @return previousMessageHash_ previous messageHash
     */
    function initiateNewInboxProcess(
        address _account,
        uint256 _nonce,
        bytes32 _messageHash
    )
        private
        returns (bytes32 previousMessageHash_)
    {
        require(
            _nonce == _getNonce(_account),
            "Invalid nonce"
        );

        previousMessageHash_ = activeProcess[_account];

        if (previousMessageHash_ != bytes32(0)) {

            require(
                messageBox.inbox[previousMessageHash_] !=
                MessageBus.MessageStatus.Progressed
                ||
                messageBox.inbox[previousMessageHash_] !=
                MessageBus.MessageStatus.Revoked,
                "Prevous process is not completed"
            );
            //TODO: Commenting below line. Please check if deleting this will
            //      effect any process related to merkle proof in other chain.
            //delete messageBox.inbox[previousMessageHash_];
        }

        // Update the active proccess.
        activeProcess[_account] = _messageHash;
    }

    /**
	 * @notice Create and return Message object.
	 *
	 * @dev This function is to avoid stack too deep error.
	 *
	 * @param _account Account address
	 * @param _accountNonce Nonce for the account address
	 * @param _gasPrice Gas price
	 * @param _gasLimit Gas limit
	 * @param _intentHash Intent hash
	 * @param _hashLock Hash lock
	 *
	 * @return Message object
	 */
	function getMessage(
		address _account,
		uint256 _accountNonce,
		uint256 _gasPrice,
		uint256 _gasLimit,
		bytes32 _intentHash,
		bytes32 _hashLock
	)
	    private
	    pure
	    returns (MessageBus.Message)
	{
		return MessageBus.Message(
            {
			    intentHash : _intentHash,
			    nonce : _accountNonce,
			    gasPrice : _gasPrice,
			    gasLimit: _gasLimit,
			    sender : _account,
			    hashLock : _hashLock,
			    gasConsumed: 0
			}
        );
	}

    /**
	 * @notice Create and return Mint object.
	 *
	 * @dev This function is to avoid stack too deep error.
	 *
	 * @param _amount Amount
	 * @param _beneficiary Beneficiary address
	 * @param _staker Redeemer address
	 * @param _stakerNonce Nonce for redeemer address
	 * @param _gasPrice Gas price
	 * @param _gasLimit Gas limit
	 * @param _intentHash Intent hash
	 * @param _hashLock Hash lock
	 *
	 * @return Unstake object
	 */
	function getMint(
		uint256 _amount,
		address _beneficiary,
		address _staker,
		uint256 _stakerNonce,
		uint256 _gasPrice,
		uint256 _gasLimit,
		bytes32 _intentHash,
		bytes32 _hashLock
	)
	    private
	    pure
	    returns (Mint)
	{
		return Mint({
			amount : _amount,
			beneficiary : _beneficiary,
			message : getMessage(
                _staker,
                _stakerNonce,
                _gasPrice,
                _gasLimit,
                _intentHash,
                _hashLock)
			});
	}

    /**
	 * @notice Private function to get the nonce for the given account address
	 *
	 * @param _account Account address for which the nonce is to fetched
	 *
	 * @return nonce
	 */
	function _getNonce(address _account)
	    private
	    view
	    returns (uint256 /* nonce */)
	{
		bytes32 messageHash = activeProcess[_account];
		if (messageHash == bytes32(0)) {
			return 0;
		}

		MessageBus.Message storage message = redeems[messageHash].message;
		return message.nonce.add(1);
	}

    //TODO: This needs discusion. This doesnt apprear correct way of implementation
    /**
     *  @notice Public function completeUtilityTokenProtocolTransfer.
     *
     *  @return bool True if protocol transfer is completed, false otherwise.
     */
    function completeUtilityTokenProtocolTransfer()
    public
    onlyOrganisation
    isActive
    returns (bool)
    {
        return ProtocolVersioned(utilityToken).completeProtocolTransfer();
    }
}
