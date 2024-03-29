import { MainNet, TestNet } from '@defichain/jellyfish-network'
import BigNumber from 'bignumber.js'
import { WhaleWalletAccount } from '@defichain/whale-api-wallet'
import { WalletClassic } from '@defichain/jellyfish-wallet-classic'
import { WIF } from '@defichain/jellyfish-crypto'

import { ethers, providers } from 'ethers'

import { ConvertDirection, createSignedTransferDomainTx, getAddressFromDST20TokenId } from './TransferDomainHelper'
import { OceanAccess } from './OceanAccess'
import { Script } from '@defichain/jellyfish-transaction'
import { fromAddress } from '@defichain/jellyfish-address'

import DUSDLock from './DUSDLock.json'
import ERC20 from './ERC20.json'

async function swapAndTransferIntoSC(): Promise<void> {
  const ocean = new OceanAccess(TestNet)
  const evmProvider = new providers.JsonRpcProvider('https://dmc.mydefichain.com/' + ocean.network.name)

  const privKey = '' //needs to be provided securely

  //main account should have a few utxos for sending
  const account = new WhaleWalletAccount(ocean.client, new WalletClassic(WIF.asEllipticPair(privKey)), ocean.network)
  const dvmAddress = await account.getAddress()
  const dvmScript = fromAddress(dvmAddress, ocean.network.name)?.script as Script
  const evmAddress = await account.getEvmAddress()

  const dusdId = ocean.network == MainNet ? 15 : 11

  let nonce = await evmProvider.getTransactionCount(evmAddress) //get Nonce

  //get DUSD-DFI price
  const dusdDfi = await ocean.client.poolpairs.get('DUSD-DFI')
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

  //remaining DFI in address should go to burn
  const dfiToBurn = dfiInAddress.minus(dfiToSwap)
  const burnScript = fromAddress('8defichainBurnAddressXXXXXXXdRQkSm', ocean.network.name)!.script
  await account.withTransactionBuilder().account.accountToAccount(
    {
      from: dvmScript,
      to: [
        {
          script: burnScript,
          balances: [{ token: 0, amount: dfiToBurn }],
        },
      ],
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
    tokenId: dusdId,
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

  // send Rewards into SC
  const dusdSC = new ethers.Contract(getAddressFromDST20TokenId(dusdId), ERC20.abi, signer)

  //split amount 3/8 to 1 year lock and 5/8 to 2 year lock

  const lock1Rewards = amount.times(3).div(8)
  const lock2Rewards = amount.minus(lock1Rewards)

  const lock1SCAddress = '0x...'
  const lock1SC = new ethers.Contract(lock1SCAddress, DUSDLock.abi, signer)

  const lock2SCAddress = '0x...'
  const lock2SC = new ethers.Contract(lock2SCAddress, DUSDLock.abi, signer)

  const approve1Tx = await signAndSendEVMTx(
    signer,
    await dusdSC.populateTransaction.approve(lock1SCAddress, lock1Rewards),
    100_000,
    nonce,
    chainId,
    evmProvider,
  )
  nonce++

  const approve2Tx = await signAndSendEVMTx(
    signer,
    await dusdSC.populateTransaction.approve(lock2SCAddress, lock2Rewards),
    100_000,
    nonce,
    chainId,
    evmProvider,
  )
  nonce++

  const rewards1Tx = await signAndSendEVMTx(
    signer,
    await lock1SC.populateTransaction.addRewards(lock1Rewards),
    100_000,
    nonce,
    chainId,
    evmProvider,
  )
  nonce++

  const rewards2Tx = await signAndSendEVMTx(
    signer,
    await lock2SC.populateTransaction.addRewards(lock2Rewards),
    100_000,
    nonce,
    chainId,
    evmProvider,
  )
  nonce++
}

// helper for sending EVM tx

async function signAndSendEVMTx(
  signer: ethers.Wallet,
  tx: ethers.PopulatedTransaction,
  gasLimit: number,
  nonce: number,
  chainId: number,
  provider: ethers.providers.Provider,
): Promise<ethers.providers.TransactionResponse> {
  tx.chainId = chainId
  tx.gasLimit = ethers.BigNumber.from(gasLimit)
  tx.maxFeePerGas = ethers.BigNumber.from(20)
  tx.nonce = nonce
  const signedTx = await signer.signTransaction(tx)
  return await provider.sendTransaction(signedTx)
}
