import { MainNet, TestNet } from '@defichain/jellyfish-network'
import BigNumber from 'bignumber.js'
import { WhaleWalletAccount } from '@defichain/whale-api-wallet'
import { WalletClassic } from '@defichain/jellyfish-wallet-classic'
import { WIF } from '@defichain/jellyfish-crypto'

import { ethers, providers } from 'ethers'

import { ConvertDirection, createSignedTransferDomainTx } from './TransferDomainHelper'
import { OceanAccess } from './OceanAccess'
import { Script } from '@defichain/jellyfish-transaction'
import { fromAddress } from '@defichain/jellyfish-address'

import DUSDLock from './DUSDLock.json'

async function swapAndTransfer(): Promise<void> {
  const ocean = new OceanAccess(TestNet)
  const evmProvider = new providers.JsonRpcProvider('https://dmc.mydefichain.com/' + ocean.network.name)

  const privKey = '' //needs to be provided securely

  //main account should have a few utxos for sending
  const account = new WhaleWalletAccount(ocean.client, new WalletClassic(WIF.asEllipticPair(privKey)), ocean.network)
  const dvmAddress = await account.getAddress()
  const dvmScript = fromAddress(dvmAddress, ocean.network.name)?.script as Script
  const evmAddress = await account.getEvmAddress()

  const tokenId = ocean.network == MainNet ? 15 : 11

  let nonce = await evmProvider.getTransactionCount(evmAddress) //get Nonce

  //get DUSD-DFI price
  const dusdDfi = await ocean.client.poolpairs.get('DUSD-DFI')
  const dusdId = +dusdDfi.tokenA.id
  const price = dusdDfi.priceRatio.ab

  // calc max DFI to swap (capped to 20 DUSD/block)
  const blocksSinceLastRun = 2880 //TODO: replace with actual blocks since last run

  const dfiInAddress = new BigNumber(
    (await ocean.client.address.listToken(dvmAddress)).find((t) => +t.id == 0)?.amount ?? 0,
  )
  const dfiFromCap = new BigNumber(blocksSinceLastRun * 20).div(price) //max 20 DUSD/block
  const dfiToSwap = BigNumber.min(dfiInAddress, dfiFromCap)
  // swap DFI -> DUSD
  const swap = await account.withTransactionBuilder().dex.poolSwap(
    {
      fromScript: dvmScript,
      fromTokenId: 0,
      fromAmount: dfiToSwap,
      toScript: dvmScript,
      toTokenId: dusdId,
      maxPrice: new BigNumber(9999999),
    },
    dvmScript,
  )
  await ocean.sendAndWait(swap)

  //transfer to evm
  const amount = new BigNumber(
    (await ocean.client.address.listToken(dvmAddress)).find((t) => +t.id == dusdId)?.amount ?? 0,
  )

  const chainId = ocean.network == MainNet ? 1130 : 1131

  const tdTx = await createSignedTransferDomainTx({
    account,
    tokenId,
    amount: amount,
    convertDirection: ConvertDirection.dvmToEvm,
    dvmAddress,
    evmAddress,
    chainId,
    networkName: ocean.network.name,
    nonce: nonce,
  })

  await ocean.sendAndWait(tdTx)

  nonce = await evmProvider.getTransactionCount(evmAddress)
  const signer = new ethers.Wallet(await account.privateKey(), evmProvider)

  //TODO: approve DUSD amount on EVM side

  // create call to Bot SC
  const lockSCAddress = '0x...'

  const lockSC = new ethers.Contract(lockSCAddress, DUSDLock, signer)
  const txUnsigned = await lockSC.populateTransaction.addRewards(amount)

  txUnsigned.chainId = chainId
  txUnsigned.gasLimit = ethers.BigNumber.from(200_000) //TODO: add real gaslimit
  txUnsigned.maxFeePerGas = ethers.BigNumber.from(20)
  txUnsigned.nonce = nonce
  const signedTx = await signer.signTransaction(txUnsigned)
  const submittedTx = await evmProvider.sendTransaction(signedTx)
}

// helper for sending
