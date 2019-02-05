// Copyright 2019 OpenST Ltd.
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

const assert = require('assert');
const BN = require('bn.js');

/**
 * Redeem Request object contains all the properties for redeem and unStake.
 * @typedef {Object} RedeemRequest
 * @property {BN} amount Redeem amount.
 * @property {BN} gasPrice Gas price that Redeemer is ready to pay to get the
 *                         redeem and unStake process done.
 * @property {BN} gasLimit Gas limit that redeemer is ready to pay.
 * @property {string} redeemer Address of Redeemer.
 * @property {BN} bounty Bounty amount paid for redeem and unstake message
 *                       transfers.
 * @property {BN} nonce Redeem nonce.
 * @property {string} beneficiary Address of beneficiary on origin chain.
 * @property {string} hashLock Hash Lock provided by the redeemer.
 * @property {string} unlockSecret Unlock secret to unlock hash lock.
 * @property {string} messageHash Identifier for redeem and unstake process.
 * @property {BN} blockHeight Height at which anchor state root is done.
 */

/**
 * BaseToken(ETH) and OSTPrime ERC20 balance of cogateway, redeemer.
 * @typedef {Object} Balances
 * @property balances.ostPrime.cogateway ERC20 balance of cogateway contract.
 * @property balances.ostPrime.redeemer ERC20 balance of beneficiary.
 * @property balances.baseToken.cogateway Base token(ETH) balance of cogateway.
 * @property balances.baseToken.redeemer Base token(ETH) balance of redeemer.
 */

/**
 *  Class to assert event and balances after progress redeem.
 */
class ProgressRedeemAssertion {
    /**
     * Constructor.
     * @param {Object} cogateway Truffle cogateway instance.
     * @param {Object} ostPrime Truffle token instance.
     * @param {Web3} web3 Web3 instance.
     */
    constructor(cogateway, ostPrime, web3) {
        this.cogateway = cogateway;
        this.token = ostPrime;
        this.web3 = web3;
    }

    /**
     * This verifies event and balances.
     * @param {Object} event Event object after decoding.
     * @param {RedeemRequest} redeemRequest Redeem request parameter.
     * @param {number} transactionFees Transaction fees in redeem request.
     * @param {Balances} initialBalances Initial baseToken and token balances.
     */
    async verify(event, redeemRequest, transactionFees, initialBalances) {
        await this._assertBalancesForRedeem(
            redeemRequest,
            initialBalances,
            transactionFees,
        );

        ProgressRedeemAssertion._assertProgressRedeemEvent(event, redeemRequest);
    }

    /**
     * This captures base token and token balance of cogateway and redeemer
     * @param {string} redeemer Redeemer address.
     * @return {Promise<Balances>}
     */
    async captureBalances(redeemer) {
        return {
            baseToken: {
                cogateway: await this._getEthBalance(this.cogateway.address),
                redeemer: await this._getEthBalance(redeemer),
            },
            token: {
                cogateway: await this.token.balanceOf(this.cogateway.address),
                redeemer: await this.token.balanceOf(redeemer),
            },
        };
    }

    /**
     * This asserts balances of redeemer and cogateway after progress Redeem.
     * @param redeemRequest Redeem request parameters.
     * @param {Balances} initialBalances Initial balance of redeemer and cogateway
     *                                   generated by captureBalances method.
     * @param {number} transactionFees Transaction fees in redeem request.
     * @private
     */
    async _assertBalancesForRedeem(redeemRequest, initialBalances, transactionFees) {
        const finalBalances = await this.captureBalances(redeemRequest.redeemer);

        // Assert cogateway balance.
        const expectedCoGatewayBaseTokenBalance = initialBalances.baseToken.cogateway
            .sub(redeemRequest.bounty);

        // Assert bounty is transferred from cogateway.
        assert.strictEqual(
            expectedCoGatewayBaseTokenBalance.eq(finalBalances.baseToken.cogateway),
            true,
            `CoGateway base token balance must be ${expectedCoGatewayBaseTokenBalance.toString(10)}`
          + ` instead of ${finalBalances.baseToken.cogateway.toString(10)}`,
        );

        const expectedCoGatewayTokenBalance = initialBalances.token.cogateway
            .sub(redeemRequest.amount);

        // Assert Redeem amount is transferred from cogateway.
        assert.strictEqual(
            expectedCoGatewayTokenBalance.eq(finalBalances.token.cogateway),
            true,
            `CoGateway token balance must be ${expectedCoGatewayBaseTokenBalance.toString(10)}`
          + ` instead of ${finalBalances.token.cogateway.toString(10)}`,
        );

        // Assert redeemer balance
        const expectedRedeemerBaseTokenBalance = initialBalances.baseToken.redeemer
            .add(redeemRequest.bounty).sub(transactionFees);

        // Assert bounty is transferred to redeemer.
        assert.strictEqual(
            expectedRedeemerBaseTokenBalance.eq(finalBalances.baseToken.redeemer),
            true,
            `Redeemer base token balance must be ${expectedRedeemerBaseTokenBalance.toString(10)}`
          + ` instead of ${finalBalances.baseToken.redeemer.toString(10)}`,
        );

        const expectedRedeemerTokenBalance = initialBalances.token.redeemer;

        assert.strictEqual(
            expectedRedeemerTokenBalance.eq(finalBalances.token.redeemer),
            true,
            `Redeemer token balance must be ${expectedRedeemerTokenBalance.toString(10)}`
          + ` instead of ${finalBalances.token.redeemer.toString(10)}`,
        );
    }

    /**
     * This assert event after Redeem method.
     * @param {Object} event Event object after decoding.
     * @param {RedeemRequest} redeemRequest Redeem request parameters.
     * @private
     */
    static _assertProgressRedeemEvent(event, redeemRequest) {
        const eventData = event.RedeemProgressed;

        assert.strictEqual(
            eventData._messageHash,
            redeemRequest.messageHash,
            'Message hash from event is different from expected.',
        );

        assert.strictEqual(
            eventData._redeemer,
            redeemRequest.redeemer,
            `Redeemer address from event ${eventData._redeemer} must be equal to ${redeemRequest.redeemer}.`,
        );

        assert.strictEqual(
            redeemRequest.nonce.eq(eventData._redeemerNonce),
            true,
            `Redeemer nonce from event ${eventData._redeemerNonce} 
            must be equal to ${redeemRequest.nonce.toString(10)}.`,
        );

        assert.strictEqual(
            redeemRequest.amount.eq(eventData._amount),
            true,
            `Amount from event ${eventData._amount} must be equal 
            to ${redeemRequest.amount.toString(10)}.`,
        );

        assert.strictEqual(
            eventData._proofProgress,
            false,
            'Proof progress flag should be false.',
        );

        assert.strictEqual(
            eventData._unlockSecret,
            redeemRequest.unlockSecret,
            'Unlock secret must match.',
        );
    }

    /**
     * Returns ETH balance wrapped in BN.
     * @param {string} address Address for which balance is requested.
     * @return {Promise<BN>} ETH Balance.
     * @private
     */
    async _getEthBalance(address) {
        const balance = await this.web3.eth.getBalance(address);
        return new BN(balance);
    }
}

module.exports = ProgressRedeemAssertion;
