import { MainNet, TestNet } from '@defichain/jellyfish-network'
import BigNumber from 'bignumber.js'
import { WhaleWalletAccount } from '@defichain/whale-api-wallet'
import { WalletClassic } from '@defichain/jellyfish-wallet-classic'
import { WIF } from '@defichain/jellyfish-crypto'

import { providers } from 'ethers'

import { ConvertDirection, createSignedTransferDomainTx } from './TransferDomainHelper'
import { OceanAccess } from './OceanAccess'

async function swapAndTransfer(): Promise<void> {
  const ocean = new OceanAccess(TestNet)
  const evmProvider = new providers.JsonRpcProvider('https://dmc.mydefichain.com/' + ocean.network.name)

  const privKey = '' //needs to be provided securely

  //main account should have a few utxos for sending
  const account = new WhaleWalletAccount(ocean.client, new WalletClassic(WIF.asEllipticPair(privKey)), ocean.network)
  const dvmAddress = await account.getAddress()
  const evmAddress = await account.getEvmAddress()

  const tokenId = ocean.network == MainNet ? 15 : 11

  const nonce = await evmProvider.getTransactionCount(evmAddress) //get Nonce

  //get DUSD-DFI price
  // calc max DFI to swap (capped to 20 DUSD/block)
  // swap DFI -> DUSD

  //transfer to evm

  const amount = new BigNumber(0)

  const tdTx = await createSignedTransferDomainTx({
    account,
    tokenId,
    amount: amount,
    convertDirection: ConvertDirection.dvmToEvm,
    dvmAddress,
    evmAddress,
    chainId: ocean.network == MainNet ? 1130 : 1131,
    networkName: ocean.network.name,
    nonce: nonce,
  })

  await ocean.sendAndWait(tdTx)

  // create call to Bot SC
  const lockSCAddress = '0x...'
}

// helper for sending
