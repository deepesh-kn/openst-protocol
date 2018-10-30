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

const AuxStoreUtils = require('./helpers/aux_store_utils.js');
const BN = require('bn.js');
const EventDecoder = require('../../test_lib/event_decoder.js');
const Utils = require('../../test_lib/utils.js');

const TestData = require('./helpers/data.js');

const AuxiliaryBlockStore = artifacts.require('AuxiliaryBlockStore');
const BlockStoreMock = artifacts.require('BlockStoreMock');

contract('AuxiliaryBlockStore.reportBlock()', async (accounts) => {

    let coreIdentifier = '0x0000000000000000000000000000000000000001';
    let epochLength = new BN('3');
    let pollingPlaceAddress = accounts[0];
    let originBlockStore;
    let testBlocks = TestData.blocks;
    let initialBlockHash = TestData.initialBlock.hash;
    let initialStateRoot = TestData.initialBlock.stateRoot;
    let initialGas = TestData.initialBlock.gas;
    let initialTransactionRoot = TestData.initialBlock.transactionRoot;
    let initialHeight = TestData.initialBlock.height;

    let blockStore;

    beforeEach(async () => {
        originBlockStore = await BlockStoreMock.new();

        blockStore = await AuxiliaryBlockStore.new(
            coreIdentifier,
            epochLength,
            pollingPlaceAddress,
            originBlockStore.address,
            initialBlockHash,
            initialStateRoot,
            initialHeight,
            initialGas,
            initialTransactionRoot,
        );
    });

    it('should accept a valid report', async () => {
        for (let i in testBlocks) {
            let testBlock = testBlocks[i];

            await blockStore.reportBlock(testBlock.header);

            let reported = await blockStore.isBlockReported.call(testBlock.hash);
            assert.strictEqual(
                reported,
                true,
                'A reported block must be registered as reported.'
            );
        }
    });

    it('should emit an event when a block is reported', async () => {
        for (let i in testBlocks) {
            let testBlock = testBlocks[i];

            let tx = await blockStore.reportBlock(testBlock.header);

            let event = EventDecoder.getEvents(tx, blockStore);
            assert.strictEqual(
                event.BlockReported.blockHash,
                testBlock.hash
            );
        }
    });

    it('should revert when the RLP encoding is invalid', async () => {
        // Changed the first character
        let invalidEncodedHeader = '0xa901f9a07f1034f3d32a11c606f8ae8265344d2ab06d71500289df6f9cac2e013990830ca01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347948888f1f195afa192cfee860698584c030f4c9db1a0ef1552a40b7165c3cd773806b9e0c165b75356e0314bf0706f279c729f51e017a05fe50b260da6308036625b850b5d6ced6d0a9f814c0688bc91ffb7b7a3a54b67a0bc37d79753ad738a6dac4921e57392f145d8887476de3f783dfa7edae9283e52b90100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008302000001832fefd8825208845506eb0780a0bd4472abb6659ebe3ee06ee4d7b72a00a9f4d001caca51342001075469aff49888a13a5a8c8f2bb1c4';

        await Utils.expectRevert(
            blockStore.reportBlock(
                invalidEncodedHeader
            )
        );
    });

    it('should track the accumulated gas', async () => {
        let expectedAccumulatedGas = initialGas;

        for (let i in testBlocks) {
            let testBlock = testBlocks[i];
            expectedAccumulatedGas = expectedAccumulatedGas.add(testBlock.gas);

            await blockStore.reportBlock(testBlock.header);

            let accumulatedGas = await blockStore.accumulatedGases.call(testBlock.hash);
            assert(
                accumulatedGas.eq(expectedAccumulatedGas),
                'The accumulated gas must increase by the amount of the block.',
            );
        }
    });

    it('should track the accumulated transaction root', async () => {
        let expectedAccumulatedTxRoot = initialTransactionRoot;

        for (let i in testBlocks) {
            let testBlock = testBlocks[i];

            expectedAccumulatedTxRoot = AuxStoreUtils.accumulateTransactionRoot(
                expectedAccumulatedTxRoot,
                testBlock.transactionRoot,
            );

            await blockStore.reportBlock(testBlock.header);

            let accumulatedTxRoot = await blockStore
                .accumulatedTransactionRoots
                .call(testBlock.hash);

            assert.strictEqual(
                accumulatedTxRoot,
                expectedAccumulatedTxRoot,
                'The accumulated transaction root must be correct for a new block.',
            );
        }
    });

    it('should track the origin dynasty', async () => {
        for (let i in testBlocks) {
            let testBlock = testBlocks[i];
            let expectedDynasty = new BN(i);

            await originBlockStore.setCurrentDynasty(expectedDynasty);
            await blockStore.reportBlock(testBlock.header);

            let recordedDynasty = await blockStore.originDynasties.call(testBlock.hash);
            assert(
                recordedDynasty.eq(expectedDynasty),
                'The origin dynasty must be correct for a new block.',
            );
        }
    });

    it('should track the origin head\'s hash', async () => {
        for (let i in testBlocks) {
            let testBlock = testBlocks[i];

            await originBlockStore.setHead(testBlock.hash);
            await blockStore.reportBlock(testBlock.header);

            let recordedHead = await blockStore.originBlockHashes.call(testBlock.hash);
            assert.strictEqual(
                recordedHead,
                testBlock.hash,
                'The origin head hash must be correct for a new block.',
            );
        }
    });

});
