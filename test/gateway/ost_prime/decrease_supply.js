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

const OSTPrime = artifacts.require("TestOSTPrime")
  , BN = require('bn.js');

const Utils = require('../../../test/test_lib/utils');
const EventDecoder = require('../../test_lib/event_decoder.js');
const NullAddress = "0x0000000000000000000000000000000000000000";

contract('OSTPrime.decreaseSupply()', function (accounts) {

  const DECIMAL = new BN(10);
  const POW = new BN(18);
  const DECIMAL_FACTOR = DECIMAL.pow(POW);
  const TOKENS_MAX = new BN(800000000).mul(DECIMAL_FACTOR);

  let brandedTokenAddress,
    ostPrime,
    callerAddress,
    amount,
    membersManager,
    coGatewayAddress;

  async function initialize(){
    await ostPrime.initialize(
      {from: accounts[2], value:TOKENS_MAX}
    );
  };

  beforeEach(async function () {

    membersManager = accounts[0];
    brandedTokenAddress = accounts[2];
    ostPrime = await OSTPrime.new(brandedTokenAddress, membersManager);

    callerAddress = accounts[3];
    amount = new BN(1000);

    await ostPrime.setTokenBalance(callerAddress, amount);

    coGatewayAddress = accounts[1];

    await ostPrime.setCoGatewayAddress(coGatewayAddress);
    await ostPrime.setTokenBalance(coGatewayAddress, amount);
    await ostPrime.setTotalSupply(amount);

  });

  it('should fail when decrease supply amount is zero', async function () {

    await initialize();

    amount = new BN(0);

    await Utils.expectRevert(
      ostPrime.decreaseSupply(amount, { from: coGatewayAddress }),
      'Amount should be greater than zero.',
    );

  });

  it('should fail when caller is not cogateway address', async function () {

    await initialize();

    await Utils.expectRevert(
      ostPrime.decreaseSupply(amount, { from: accounts[5] }),
      'Only CoGateway can call the function.',
    );

  });

  it('should fail when OST Prime contract is not initialized', async function () {

    await Utils.expectRevert(
      ostPrime.decreaseSupply(amount, { from: coGatewayAddress }),
      'Contract is not initialized.',
    );

  });

  it('should fail when decrease supply amount is less than the available' +
    ' balance', async function () {

    await initialize();

    amount = new BN(2000);

    await Utils.expectRevert(
      ostPrime.decreaseSupply(amount, { from: coGatewayAddress }),
      'Insufficient balance.',
    );

  });

  it('should pass when called with valid params', async function () {

    await initialize();

    amount = new BN(500);

    let result = await ostPrime.decreaseSupply.call(
      amount, { from: coGatewayAddress }
    );

    assert.strictEqual(
      result,
      true,
      'Contract should return true.',
    );

    await ostPrime.decreaseSupply(amount, { from: coGatewayAddress });

    let coGatewayBalance = await ostPrime.balanceOf.call(coGatewayAddress);

    assert.strictEqual(
      coGatewayBalance.eqn(500),
      true,
      'CoGateway address balance should be 500.',
    );

    let totalSupply = await ostPrime.totalSupply();
    assert.strictEqual(
      totalSupply.eqn(500),
      true,
      'Token total supply from contract must be equal to 500.',
    );

  });

  it('should emit transfer event', async function () {

    await initialize();

    let tx = await ostPrime.decreaseSupply(
      amount,
      { from: coGatewayAddress }
    );

    let event = EventDecoder.getEvents(tx, ostPrime);

    assert.isDefined(
      event.Transfer,
      'Event `Transfer` must be emitted.',
    );

    let eventData = event.Transfer;

    assert.strictEqual(
      eventData._from,
      coGatewayAddress,
      `The _from address in the event should be equal to ${coGatewayAddress}.`,
    );

    assert.strictEqual(
      eventData._to,
      NullAddress,
      'The _to address in the event should be equal to zero.',
    );

    assert.strictEqual(
      amount.eq(eventData._value),
      true,
      `The _value amount in the event should be equal to ${amount}.`,
    );

  });

});