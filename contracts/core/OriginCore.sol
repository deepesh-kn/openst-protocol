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

import "../OstInterface.sol";
import "./OriginCoreConfig.sol";
import "./OriginCoreInterface.sol";
import "./Stake.sol";
import "../lib/MetaBlock.sol";
import "../lib/SafeMath.sol";
import "../lib/MetaBlock.sol";

/**
 * @title OriginCore is a meta-blockchain with staked validators on Ethereum.
 */
contract OriginCore is OriginCoreInterface, OriginCoreConfig {
    using SafeMath for uint256;

    /* Events */

    /** Emitted whenever a block is successfully reported. */
    event BlockReported(
        uint256 indexed height,
        bytes32 indexed blockHash
    );

    /** Emitted whenever a meta-block is proposed. */
    event BlockProposed(
        uint256 indexed height,
        bytes32 indexed kernelHash,
        bytes32 transitionHash
    );

    /** Emitted whenever a vote is verified for proposed meta-block. */
    event VoteVerified(
        bytes32 indexed kernelHash,
        bytes32 transitionHash,
        address validator,
        bytes32 voteHash,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 verifiedWeight,
        uint256 requiredWeight
    );

    /* Public Variables */

    OstInterface public Ost;

    /** The core identifier of the tracked auxiliary chain. */
    bytes20 public auxiliaryCoreIdentifier;

    /** The stake contract that tracks deposits and weights. */
    StakeInterface public stake;

    /** Height of the open block. */
    uint256 public height;

    /** head is the block header hash of the latest committed block. */
    bytes32 public head;

    /**
     * The maximum amount of gas that a meta-block could accumulate on an
     * auxiliary chain before proposing a new meta-block.
     */
    uint256 public maxAccumulateGasLimit;

    /**
     * Mapping of block hashes to block headers that were reported with the
     * respective hash.
     */
    mapping (bytes32 => MetaBlock.Header) public reportedHeaders;

    /**
     * Mapping of kernel hash to transition object map,
     * where transition object map is transition hash to transition mapping.
     */
    mapping(bytes32 => mapping(bytes32 => MetaBlock.AuxiliaryTransition)) public proposedMetaBlock;

    /**
     * Mapping of transition object which were proposed for current open
     * meta-block with seal i.e. votes by validators.
     */
    mapping(bytes32 => MetaBlock.Seal) public seals;

    /* Constructor */

    /**
     * The OriginCore constructor initializes the OriginCore and deploys an
     * instance of the Stake contract.
     *
     * @param _auxiliaryCoreIdentifier The core identifier of the auxiliary
     *                                 chain that this core contract tracks.
     * @param _ost The address of the OST ERC-20 token.
     * @param _initialAuxiliaryGas Initial gas consumed on auxiliary before
     *                             reporting genesis meta-block.
     * @param _initialTransactionRoot Transaction root of auxiliary chain
     *                                before reporting genesis meta-block.
     * @param _minimumWeight The minimum total weight that all active validators
     *                       of this meta-blockchain must have so that the
     *                       meta-blockchain is not considered halted. Used in
     *                       the constructor of the Stake contract.
     * @param _maxAccumulateGasLimit The maximum amount of gas that a
     *                               meta-block could accumulate on an
     *                               auxiliary chain before proposing a new
     *                               meta-block.
     */
    constructor(
        bytes20 _auxiliaryCoreIdentifier,
        address _ost,
        uint256 _initialAuxiliaryGas,
        bytes32 _initialTransactionRoot,
        uint256 _minimumWeight,
        uint256 _maxAccumulateGasLimit
    )
        public
    {
        require(_ost != address(0), "Address for OST should not be zero.");
        require(
            _initialTransactionRoot != bytes32(0),
            "Auxiliary transaction root should be defined."
        );
        require(
            _maxAccumulateGasLimit != uint256(0),
            "Max accumulated gas limit should not be zero."
        );

        auxiliaryCoreIdentifier = _auxiliaryCoreIdentifier;
        Ost = OstInterface(_ost);
        maxAccumulateGasLimit = _maxAccumulateGasLimit;

        // deploy stake contract
        stake = new Stake(
            _ost,
            address(this),
            _minimumWeight
        );
        head = reportGenesisBlock(
            _initialAuxiliaryGas,
            _initialTransactionRoot
        );
    }

    /* External Functions */

    /**
     * @notice Proposes a new meta-block. The block is stored if the proposal
     *         succeeds, but its votes still need to be verified in order for
     *         it to be committed.
     *
     * @param _height Height of the meta-block in the chain of meta-blocks.
     * @param _coreIdentifier A unique identifier that identifies what chain
     *                        this vote is about.
     * @param _kernelHash The hash of the current kernel.
     * @param _auxiliaryDynasty The dynasty number where the meta-block closes
     *                          on the auxiliary chain.
     * @param _auxiliaryBlockHash The block hash where the meta-block closes
     *                          on the auxiliary chain.
     * @param _accumulatedGas The total consumed gas on auxiliary within
     *                        this meta-block.
     * @param _originDynasty Dynasty of origin block within latest meta-block
     *                          reported at auxiliary chain.
     * @param _originBlockHash Block hash of origin block within latest
     *                          meta-block reported at auxiliary chain.
     * @param _transactionRoot The transaction root of the meta-block. A trie
     *                         created by the auxiliary block store from the
     *                         transaction roots of all blocks.
     * @return `true` if the proposal succeeds.
     */
    function proposeBlock(
        uint256 _height,
        bytes20 _coreIdentifier,
        bytes32 _kernelHash,
        uint256 _auxiliaryDynasty,
        bytes32 _auxiliaryBlockHash,
        uint256 _accumulatedGas,
        uint256 _originDynasty,
        bytes32 _originBlockHash,
        bytes32 _transactionRoot
    )
        external
        returns (bool)
    {

        require(
            _kernelHash != bytes32(0),
            "Kernel hash should not be `0`."
        );

        require(
            _originDynasty > 0,
            "Origin dynasty should not be `0`."
        );

        require(
            _originBlockHash != bytes32(0),
            "Origin block should not be `0`."
        );

        require(
            _transactionRoot != bytes32(0),
            "Transaction Root hash should not be `0`."
        );

        require(
            _coreIdentifier == auxiliaryCoreIdentifier,
            "CoreIdentifier should be same as auxiliary core identifier."
        );

        /* header of last meta block */
        MetaBlock.Header storage latestMetaBlockHeader = reportedHeaders[head];

        require(
            latestMetaBlockHeader.kernel.height.add(1) == _height,
            "Height should be one more than last meta-block."
        );

        require(
            _auxiliaryDynasty > latestMetaBlockHeader.transition.auxiliaryDynasty,
            "Auxiliary dynasty should be greater than last meta-block auxiliary dynasty."
        );

        require(
            _accumulatedGas > latestMetaBlockHeader.transition.accumulatedGas,
            "Gas consumed should be greater than last meta-block gas."
        );

        bytes32 transitionHash = MetaBlock.hashAuxiliaryTransition(
            _coreIdentifier,
            _kernelHash,
            _auxiliaryDynasty,
            _auxiliaryBlockHash,
            _accumulatedGas,
            _originDynasty,
            _originBlockHash,
            _transactionRoot
        );
        require(
            proposedMetaBlock[_kernelHash][transitionHash].kernelHash == bytes32(0),
            "Meta-block with same transition object is already proposed."
        );

        proposedMetaBlock[_kernelHash][transitionHash] = MetaBlock.AuxiliaryTransition(
            _coreIdentifier,
            _kernelHash,
            _auxiliaryDynasty,
            _auxiliaryBlockHash,
            _accumulatedGas,
            _originDynasty,
            _originBlockHash,
            _transactionRoot
        );
        emit BlockProposed(_height, _kernelHash, transitionHash);

        return true;
    }

    /**
     * @notice Verifies a vote that justified the direct child checkpoint of
     *         the last justified auxiliary checkpoint in the meta-block. A
     *         super majority of such votes finalise the last auxiliary
     *         checkpoint of this meta-block.
     *
     * @dev Must track which votes have already been verified so that the same
     *      vote never gets verified more than once.
     *
     * @param _kernelHash The hash of the current kernel.
     * @param _coreIdentifier A unique identifier that identifies what chain
     *                        this vote is about.
     * @param _transitionHash The hash of the transition part of the meta-block
     *                    header at the source block.
     * @param _source The hash of the source block.
     * @param _target The hash of the target block.
     * @param _sourceHeight The height of the source block.
     * @param _targetHeight The height of the target block.
     * @param _v V of the signature.
     * @param _r R of the signature.
     * @param _s S of the signature.
     *
     * @return `true` if the verification succeeded.
     */
    function verifyVote(
        bytes32 _kernelHash,
        bytes20 _coreIdentifier,
        bytes32 _transitionHash,
        bytes32 _source,
        bytes32 _target,
        uint256 _sourceHeight,
        uint256 _targetHeight,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    )
        external
        returns (bool success_)
    {
        require(
            existsMetaBlockProposal(_kernelHash, _transitionHash),
            "A vote can only be verified for an existing meta-block proposal."
        );

        bytes32 voteHash = MetaBlock.hashVote(
            _coreIdentifier,
            _transitionHash,
            _source,
            _target,
            _sourceHeight,
            _targetHeight
        );

        uint256 height;
        address signer;

        /*
         * This check the validity of vote, on successful validation it returns
         * address of validator, and height of current meta-block.
         * This will revert transaction if vote validation fails.
         */
        (height, signer) = isVoteValid(
            _transitionHash,
            voteHash,
            _v,
            _r,
            _s
        );

        uint256 verifiedWeight = saveVote(_transitionHash, signer, height);

        emit VoteVerified(
            _kernelHash,
            _transitionHash,
            signer,
            voteHash,
            _v,
            _r,
            _s,
            verifiedWeight,
            requiredWeight(stake.totalWeightAtHeight(height))
        );
    }

    /**
     * @notice The identifier of the remote chain core that is tracked by this core.
     *
     * @return The identifier of auxiliary core.
     */
    function auxiliaryCoreIdentifier()
        external
        view
        returns (bytes32)
    {
        return auxiliaryCoreIdentifier;
    }

    /**
     * @notice Returns the block height of the latest meta-block that has been
     *         committed.
     *
     * @dev A meta-block has been committed if it has been proposed and the
     *      votes have been verified.
     *
     * @return The height of the latest committed meta-block.
     */
    function latestBlockHeight()
        external
        view
        returns (uint256)
    {
        /*
         * `height` is the current open meta-block. The latest committed block
         * is therefore at `height - 1`.
         */
        return height.sub(1);
    }

    /**
     * @notice Get the state root of a meta-block.
     *
     * @param _blockHeight For which blockheight to get the state root.
     *
     * @return The state root of the meta-block.
     */
    function getStateRoot(
        uint256 _blockHeight
    )
        external
        view
        returns (bytes32 stateRoot_)
    {
        revert("Method not implemented.");
    }

    /**
     * @notice Get accumulated gas target for next meta-block.
     *
     * @return Accumulated gas target.
     */
    function getAccumulatedGasTarget()
        external
        view
        returns (uint256 accumulateGasTarget_)
    {
        MetaBlock.Header storage lastCommittedMetaBlock = reportedHeaders[head];
        accumulateGasTarget_ = lastCommittedMetaBlock.transition.accumulatedGas.add(
            maxAccumulateGasLimit
        );
    }

    /* Private Functions */

    /**
     * @notice private method to create genesis block.
     *
     * @param _initialAuxiliaryGas Initial gas consumed on auxiliary before
     *                             reporting genesis meta-block.
     * @param _initialTransactionRoot Transaction root of auxiliary chain
     *                                before reporting genesis meta-block.
     *
     * @return bytes32 head of meta-block chain pointing to genesis block.
     */
    function reportGenesisBlock(
        uint256 _initialAuxiliaryGas,
        bytes32 _initialTransactionRoot
    )
        private
        returns (bytes32)
    {
        address[] memory initialValidators;
        uint256[] memory validatorsWeights;
       /*
        * Kernel for genesis block with height 0, no parent block and
        * initial set of validators with their weights.
        */
        MetaBlock.Kernel memory genesisKernel = MetaBlock.Kernel(
            0,
            bytes32(0),
            initialValidators,
            validatorsWeights
        );
        bytes32 kernelHash = MetaBlock.hashKernel(
            0,
            bytes32(0),
            initialValidators,
            validatorsWeights
        );

        /*
         * Transition object for genesis block with all parameter as 0 except
         * auxiliaryCoreIdentifier, kernel Hash, gas and transactionRoot.
         */
        MetaBlock.AuxiliaryTransition memory genesisTransition = MetaBlock.AuxiliaryTransition(
            auxiliaryCoreIdentifier,
            kernelHash,
            0,
            bytes32(0),
            _initialAuxiliaryGas,
            0,
            bytes32(0),
            _initialTransactionRoot
        );

        reportedHeaders[kernelHash] = MetaBlock.Header(genesisKernel, genesisTransition);

        return kernelHash;
    }

    /**
     * @notice This function checks vote validity.
     *
     * @dev This method will revert the transaction if validator is not
     *       eligible for voting.
     *
     * @param _transitionHash The hash of the transition part of the meta-block
     *                    header at the source block.
     * @param _voteHash The hash of the vote object.
     * @param _v V of the signature.
     * @param _r R of the signature.
     * @param _s S of the signature.
     *
     * @return currentHeight_ Height of current meta-block.
     * @return signer_ Address of validator who has signed the vote.
     */
    function isVoteValid(
        bytes32 _transitionHash,
        bytes32 _voteHash,
        uint8 _v,
        bytes32 _r,
        bytes32 _s

    )
        private
        view
        returns (uint256 currentHeight_, address signer_)
    {
        // As per https://github.com/ethereum/go-ethereum/pull/2940
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        _voteHash = keccak256(
            abi.encodePacked(
                prefix,
                _voteHash
            )
        );

        signer_ = ecrecover(
            _voteHash,
            _v,
            _r,
            _s
        );

        /* Header of last meta block. */
        MetaBlock.Header storage latestMetaBlockHeader = reportedHeaders[head];
        /* Current meta-block height. */
        currentHeight_ = latestMetaBlockHeader.kernel.height.add(1);
        uint256 weight = stake.weight(currentHeight_, signer_);

        require(
            weight > 0,
            "Only validator with non zero weight can vote."
        );

        require(
            seals[_transitionHash].validators[signer_] == false,
            "Vote already verified for this validator."
        );

    }

    /**
     * @notice This function saves vote into the seal.
     *
     * @dev This method assumes that vote has been successfully verified. It
     *      will revert the transaction if validator already voted for this
     *      transition object.
     *
     * @param _transitionHash The hash of the transition part of the meta-block
     *                    header at the source block.
     * @param _signer Address of validator who has signed vote object.
     * @param _height Height of current meta-block.
     */
    function saveVote(
        bytes32 _transitionHash,
        address _signer,
        uint256 _height
    )
        private
        returns(uint256 totalVoteWeight_)
    {
        MetaBlock.Seal storage seal = seals[_transitionHash];

        seal.validators[_signer] = true;

        totalVoteWeight_ = seal.totalVoteWeight.add(stake.weight(_height,_signer));

        seal.totalVoteWeight = totalVoteWeight_;

        //seals[_transition] = seal;
    }

    /**
     * @notice This function checks if meta-block proposal exists.
     *
     * @param _kernelHash The hash of the current kernel.
     * @param _transitionHash The hash of the transition object which is proposed
     *                    with meta-block.
     * @return bool `true` If meta-block proposal exists.
     */
    function existsMetaBlockProposal(
        bytes32 _kernelHash,
        bytes32 _transitionHash
    )
        private
        view
        returns(bool)
    {
        MetaBlock.AuxiliaryTransition storage transitionObject =
            proposedMetaBlock[_kernelHash][_transitionHash];

        return transitionObject.kernelHash == _kernelHash;
    }

    /**
     * @notice Function to calculated weight required for super majority
     *         i.e 2/3rd of total weight.
     *
     * @param _totalWeight Total weight of all the validators at current
     *                     meta-block height.
     * @return uint256 Required weight for 2/3rd super majority.
     */
    function requiredWeight(uint256 _totalWeight)
        private
        pure
        returns(uint256)
    {
        return _totalWeight.mul(2).div(3);
    }
}
