/*
    as seen in LW implementation: TODO: add source
*/
import { NetworkName } from '@defichain/jellyfish-network'
import BigNumber from 'bignumber.js'
import { WhaleWalletAccount } from '@defichain/whale-api-wallet'
import { CTransactionSegWit, Script, TransferDomain } from '@defichain/jellyfish-transaction'

import { fromAddress, Eth } from '@defichain/jellyfish-address'
import { Prevout } from '@defichain/jellyfish-transaction-builder'
import { ethers, providers, utils } from 'ethers'
import TransferDomainV1 from './TransferDomainV1.json'

export enum ConvertDirection {
  evmToDvm = 'evmToDvm',
  dvmToEvm = 'dvmToEvm',
  utxosToAccount = 'utxosToAccount',
  accountToUtxos = 'accountToUtxos',
}

export const TD_CONTRACT_ADDR = '0xdf00000000000000000000000000000000000001'

const TRANSFER_DOMAIN_TYPE = {
  DVM: 2,
  EVM: 3,
}

interface TransferDomainSigner {
  account: WhaleWalletAccount
  tokenId: number
  amount: BigNumber
  convertDirection: ConvertDirection
  dvmAddress: string
  evmAddress: string
  chainId?: number
  networkName: NetworkName
  nonce: number
}

async function getTransferDomainVin(
  account: WhaleWalletAccount,
  networkName: NetworkName,
): Promise<{ utxos: Prevout[]; walletOwnerDvmScript: Script }> {
  const walletOwnerDvmAddress = await account.getAddress()
  const walletOwnerDvmScript = fromAddress(walletOwnerDvmAddress, networkName)?.script as Script

  const utxoList = await account.client.address.listTransactionUnspent(walletOwnerDvmAddress)

  const utxos: Prevout[] = []
  if (utxoList.length > 0) {
    const utxo = utxoList[0]
    utxos.push({
      txid: utxo.vout.txid,
      vout: utxo.vout.n,
      value: new BigNumber(utxo.vout.value),
      script: walletOwnerDvmScript,
      tokenId: utxo.vout.tokenId ?? 0,
    })
  }

  return { utxos, walletOwnerDvmScript }
}

/**
 *  Get DST20 contract address
 *  https://github.com/DeFiCh/ain/blob/f5a671362f9899080d0a0dddbbcdcecb7c19d9e3/lib/ain-contracts/src/lib.rs#L79
 */
export function getAddressFromDST20TokenId(tokenId: number | string): string {
  const parsedTokenId = BigInt(tokenId)
  const numberStr = parsedTokenId.toString(16) // Convert parsedTokenId to hexadecimal
  const paddedNumberStr = numberStr.padStart(38, '0') // Pad with zeroes to the left
  const finalStr = `ff${paddedNumberStr}`
  const tokenContractAddess = utils.getAddress(finalStr)
  return tokenContractAddess
}

export async function createSignedTransferDomainTx({
  account,
  tokenId,
  amount,
  convertDirection,
  dvmAddress,
  evmAddress,
  chainId,
  networkName,
  nonce,
}: TransferDomainSigner): Promise<CTransactionSegWit> {
  const dvmScript = fromAddress(dvmAddress, networkName)?.script as Script
  const evmScript = Eth.fromAddress(evmAddress) as Script
  const builder = account.withTransactionBuilder()

  const isEvmToDvm = convertDirection === ConvertDirection.evmToDvm

  const [sourceScript, dstScript] = isEvmToDvm ? [evmScript, dvmScript] : [dvmScript, evmScript]

  const [srcDomain, dstDomain] = isEvmToDvm
    ? [TRANSFER_DOMAIN_TYPE.EVM, TRANSFER_DOMAIN_TYPE.DVM]
    : [TRANSFER_DOMAIN_TYPE.DVM, TRANSFER_DOMAIN_TYPE.EVM]

  const signedEvmTxData = await createSignedEvmTx({
    isEvmToDvm,
    tokenId,
    amount,
    dvmAddress,
    evmAddress,
    accountEvmAddress: await account.getEvmAddress(),
    privateKey: await account.privateKey(),
    chainId,
    nonce,
  })

  const transferDomain: TransferDomain = {
    items: [
      {
        src: {
          address: sourceScript,
          domain: srcDomain,
          amount: {
            token: Number(tokenId),
            amount: amount,
          },
          data: isEvmToDvm ? signedEvmTxData : new Uint8Array([]),
        },
        dst: {
          address: dstScript,
          domain: dstDomain,
          amount: {
            token: Number(tokenId),
            amount: amount,
          },
          data: isEvmToDvm ? new Uint8Array([]) : signedEvmTxData,
        },
      },
    ],
  }

  const { utxos, walletOwnerDvmScript } = await getTransferDomainVin(account, networkName)

  const signed = await builder.account.transferDomain(transferDomain, walletOwnerDvmScript, utxos)
  return new CTransactionSegWit(signed)
}

interface EvmTxSigner {
  isEvmToDvm: boolean
  tokenId: number
  amount: BigNumber
  dvmAddress: string
  evmAddress: string
  accountEvmAddress: string
  privateKey: Buffer
  chainId?: number
  nonce: number
}

async function createSignedEvmTx({
  isEvmToDvm,
  tokenId,
  amount,
  dvmAddress,
  evmAddress,
  privateKey,
  chainId,
  nonce,
}: EvmTxSigner): Promise<Uint8Array> {
  let data
  const tdFace = new utils.Interface(TransferDomainV1.abi)
  const from = isEvmToDvm ? evmAddress : TD_CONTRACT_ADDR
  const to = isEvmToDvm ? TD_CONTRACT_ADDR : evmAddress
  const parsedAmount = utils.parseUnits(amount.decimalPlaces(8, BigNumber.ROUND_DOWN).toFixed(), 18) // TODO: Get decimals from token contract
  const vmAddress = dvmAddress

  if (tokenId === 0) {
    /* For DFI, use `transfer` function */
    const transferDfi = [from, to, parsedAmount, vmAddress]
    data = tdFace.encodeFunctionData('transfer', transferDfi)
  } else {
    /* For DST20, use `transferDST20` function */
    const dst20TokenId = tokenId
    const contractAddress = getAddressFromDST20TokenId(dst20TokenId)
    const transferDST20 = [contractAddress, from, to, parsedAmount, vmAddress]
    data = tdFace.encodeFunctionData('transferDST20', transferDST20)
  }
  const wallet = new ethers.Wallet(privateKey)

  const tx: providers.TransactionRequest = {
    to: TD_CONTRACT_ADDR,
    nonce,
    chainId,
    data: data,
    value: 0,
    gasLimit: 0,
    gasPrice: 0,
    type: 0,
  }
  const evmtxSigned = (await wallet.signTransaction(tx)).substring(2) // rm prefix `0x`
  return new Uint8Array(Buffer.from(evmtxSigned, 'hex') || [])
}
