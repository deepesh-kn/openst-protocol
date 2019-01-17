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
//
// http://www.simpletoken.org/
//
// ----------------------------------------------------------------------------

const EIP20CoGateway = artifacts.require("TestEIP20CoGateway");
const UtilityToken = artifacts.require("MockUtilityToken");
const BN = require('bn.js');
const Utils = require("./../../test_lib/utils");
const coGatewayUtils = require('./helpers/co_gateway_utils.js');
const EventDecoder = require('../../test_lib/event_decoder.js');
const messageBus = require('../../test_lib/message_bus.js');
const StubData = require('../../data/stake_revoked_1.json');

let MessageStatusEnum = messageBus.MessageStatusEnum;

async function setStateRoot(coGateway) {
  let blockHeight = new BN(StubData.gateway.revert_stake.proof_data.block_number, 16);
  let storageRoot = StubData.gateway.revert_stake.proof_data.storageHash;
  await coGateway.setStorageRoot(blockHeight, storageRoot);
  return blockHeight;
}

contract('EIP20CoGateway.confirmRevertStakeIntent() ', function (accounts) {
  let utilityToken, coGateway, owner = accounts[0], messageHash, amount,
    stakeRequest = StubData.gateway.stake.params;

  beforeEach(async function () {

    let organization = accounts[2];

    utilityToken = await UtilityToken.new(
      accounts[9],
      "Dummy", //Name
      "Dummy", //Symbol
      18, //Decimal
      organization,
      {from: owner},
    );

    coGateway = await EIP20CoGateway.new(
      StubData.contracts.mockToken,
      utilityToken.address,
      accounts[6], //dummyStateRootProvider
      StubData.co_gateway.constructor.bounty,
      organization,
      StubData.contracts.gateway,
      StubData.co_gateway.constructor.burner,
    );

    amount = new BN(stakeRequest.amount, 16);

    let intentHash = coGatewayUtils.hashStakeIntent(
      amount,
      stakeRequest.beneficiary,
      StubData.contracts.gateway,
    );

    await utilityToken.setCoGatewayAddress(coGateway.address);

    messageHash = StubData.gateway.stake.return_value.returned_value.messageHash_;

    await coGateway.setMessage(
      intentHash,
      new BN(stakeRequest.nonce, 16),
      new BN(stakeRequest.gasPrice, 16),
      new BN(stakeRequest.gasLimit, 16),
      stakeRequest.staker,
      stakeRequest.hashLock,
    );

    await coGateway.setMints(messageHash, stakeRequest.beneficiary, amount);

  });

  it('should confirm revert stake intent', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    let tx = await coGateway.confirmRevertStakeIntent(
      messageHash,
      blockHeight,
      storageProof,
    );

    assert.strictEqual(
      tx.receipt.status,
      true,
      'Transaction should success.',
    );

  });

  it('should return correct values ', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    let result = await coGateway.confirmRevertStakeIntent.call(
      messageHash,
      blockHeight,
      storageProof,
    );

    let expectedNonce = new BN(stakeRequest.nonce, 16);
    assert.strictEqual(
      result.staker_,
      stakeRequest.staker,
      `Expected staker ${stakeRequest.staker} is different from staker from 
      event ${result.staker_}`,
    );
    assert.strictEqual(
      result.stakerNonce_.eq(expectedNonce),
      true,
      `Expected stakerNonce ${expectedNonce.toString(10)} is different from nonce from 
      event ${result.stakerNonce_.toString(10)}`,
    );
    assert.strictEqual(
      result.amount_.eq(amount),
      true,
      `Expected amount ${amount.toString(10)} is different from amount from 
      event ${result.amount_.toString(10)}`,
    );

  });

  it('should emit RevertStakeIntentConfirmed event', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    let tx = await coGateway.confirmRevertStakeIntent(
      messageHash,
      blockHeight,
      storageProof,
    );

    assert.strictEqual(
      tx.receipt.status,
      true,
      'Transaction should success.',
    );

    let event = EventDecoder.getEvents(tx, coGateway);
    let eventData = event.RevertStakeIntentConfirmed;
    let expectedNonce = new BN(stakeRequest.nonce, 16);

    assert.isDefined(
      event.RevertStakeIntentConfirmed,
      'Event `RevertStakeIntentConfirmed` must be emitted.',
    );
    assert.strictEqual(
      eventData._messageHash,
      messageHash,
      `Expected message hash ${messageHash} is different from message hash from 
      event ${eventData._messageHash}`,
    );
    assert.strictEqual(
      eventData._staker,
      stakeRequest.staker,
      `Expected staker ${stakeRequest.staker} is different from staker from 
      event ${eventData._staker}`,
    );
    assert.strictEqual(
      eventData._stakerNonce.eq(expectedNonce),
      true,
      `Expected stakerNonce ${expectedNonce.toString(10)} is different from nonce from 
      event ${eventData._stakerNonce.toString(10)}`,
    );
    assert.strictEqual(
      eventData._amount.eq(amount),
      true,
      `Expected amount ${amount.toString(10)} is different from amount from 
      event ${eventData._amount.toString(10)}`,
    );

  });

  it('should fail if revert stake intent is already confirmed', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    await coGateway.confirmRevertStakeIntent(
      messageHash,
      blockHeight,
      storageProof,
    );

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        storageProof,
      ),
      'Message on target must be Declared.',
    );

  });

  it('should fail for undeclared message', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Undeclared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        storageProof,
      ),
      'Message on target must be Declared.',
    );

  });

  it('should fail for progressed message', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Progressed);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        storageProof,
      ),
      'Message on target must be Declared.',
    );

  });

  it('should fail for zero message hash', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        Utils.ZERO_BYTES32,
        blockHeight,
        storageProof,
      ),
      'Message hash must not be zero.',
    );

  });

  it('should fail for blank rlp parent nodes (storage proof)', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        '0x',
      ),
      'RLP parent nodes must not be zero.',
    );

  });

  it('should fail if storage root is not available for given block height', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = new BN(StubData.gateway.revert_stake.proof_data.block_number, 16);
    let storageProof = StubData.gateway.revert_stake.proof_data.storageProof[0].serializedProof;

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        storageProof,
      ),
      'Storage root must not be zero.',
    );

  });

  it('should fail for wrong merkle proof', async function () {

    await coGateway.setInboxStatus(messageHash, MessageStatusEnum.Declared);
    let blockHeight = await setStateRoot(coGateway);

    // Using stake proof instead of revertStake.
    let storageProof = StubData.gateway.stake.proof_data.storageProof[0].serializedProof;

    await Utils.expectRevert(
      coGateway.confirmRevertStakeIntent(
        messageHash,
        blockHeight,
        storageProof,
      ),
      'Merkle proof verification failed.',
    );

  });

});
