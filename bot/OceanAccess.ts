import { MainNet, Network } from '@defichain/jellyfish-network'
import { CTransaction, CTransactionSegWit, TransactionSegWit } from '@defichain/jellyfish-transaction'
import { WhaleApiClient, WhaleApiException } from '@defichain/whale-api-client'

export class OceanAccess {
  public client: WhaleApiClient
  public readonly network: Network

  constructor(network: Network) {
    this.client = new WhaleApiClient({
      url: network == MainNet ? 'https://ocean.mydefichain.com' : 'https://testnet-ocean.mydefichain.com:8443',
      version: 'v0',
      network: network.name,
    })
    this.network = network
  }

  async send(txn: TransactionSegWit, initialWaitTime: number = 0): Promise<CTransaction> {
    const ctx = new CTransactionSegWit(txn)
    const hex: string = ctx.toHex()
    const startBlock = (await this.client.stats.get()).count.blocks
    console.log(
      'Block ' +
        startBlock +
        ', sending txId: ' +
        ctx.txId +
        ' with input: ' +
        ctx.vin[0].txid +
        ':' +
        ctx.vin[0].index,
    )
    let retries = 0
    const waitTime = 10000
    const txId: string = await new Promise((resolve, error) => {
      let intervalID: NodeJS.Timeout
      const sendTransaction = (): void => {
        this.client.rawtx
          .send({ hex: hex })
          .then((txId) => {
            if (intervalID !== undefined) {
              clearInterval(intervalID)
            }
            resolve(txId)
          })
          .catch((e) => {
            if (retries >= 5) {
              if (intervalID !== undefined) {
                clearInterval(intervalID)
              }
              console.log('failed to send tx even after after multiple retries (' + e.error.message + ')')
              error(e)
            } else {
              let errorCode = -1
              if (e instanceof WhaleApiException) {
                errorCode = e.code
              }
              console.log(
                'error sending tx (' +
                  errorCode +
                  ': ' +
                  e.error.message +
                  '). retrying after ' +
                  (waitTime / 1000).toFixed(0) +
                  ' seconds',
              )
            }
          })
      }
      setTimeout(() => {
        //setup contiuous interval, will be cleared once the transaction is successfully sent
        intervalID = setInterval(() => {
          retries += 1
          sendTransaction()
        }, waitTime)

        //send first try (retries are done in interval)
        sendTransaction()
      }, initialWaitTime)
    })
    console.log('Transaction sent')
    return ctx
  }

  public async sendAndWait(tx: TransactionSegWit): Promise<boolean> {
    const ctx = await this.send(tx)
    return await this.waitForTx(ctx.txId)
  }

  async waitForTx(txId: string): Promise<boolean> {
    let waitingMinutes = 10
    const initialTime = 15000
    let start = initialTime
    return await new Promise((resolve) => {
      let intervalID: NodeJS.Timeout
      const callTransaction = (): void => {
        this.client.transactions
          .get(txId)
          .then((tx) => {
            if (intervalID !== undefined) {
              clearInterval(intervalID)
            }
            resolve(true)
          })
          .catch((e) => {
            if (start >= 60000 * waitingMinutes) {
              // 10 min timeout
              console.error(e)
              if (intervalID !== undefined) {
                clearInterval(intervalID)
              }
              resolve(false)
            }
          })
      }
      setTimeout(() => {
        callTransaction()
        intervalID = setInterval(() => {
          start += 15000
          callTransaction()
        }, 15000)
      }, initialTime)
    })
  }
}
