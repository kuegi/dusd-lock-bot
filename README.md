# dusd-lock-bot

sample implementation how the DUSD LOCK could be implemented.

DUSD locks provide the possibility for users to lock away their DUSD for a defined period of time and receive rewards in DUSD. Rewards are added from outside. This can be done by anyone who wants to increase incentives, but will mainly be done by a native bot that converts unused block rewards from native emissions to DUSD and adds it as rewards to the SC.

Each lockup is locked for the defined period after the deposit. So they won't get free all at once but according to the time they got added. later deposits will get freed later.

Rewards are always claimable.

## DUSD Lock as "NFT"

Ownership of a batch in the lock is defined via ERC721 Token. All data regarding the batch (lockedUntil, claimable rewards, amount...) can be queried from the SC. Be aware that transfering the token also transfer the right on claiming rewards (including all pending rewards on that token)

# deployment

This SmartContract actually ended up as the final version of DUSD Bonds on defichain. They are now deployed as 1-year and 2-year Bonds on mainnet:

https://blockscout.mainnet.ocean.jellyfishsdk.com/address/0xc5B7aAc761aa3C3f34A3cEB1333f6431d811d638

https://blockscout.mainnet.ocean.jellyfishsdk.com/address/0xD88Bb8359D694c974C9726b6201479a123212333

# contributors and donation addresses

A big THANK YOU goes out to everyone who contributed to this project. Everyone who tested, gave feedback and of course actually helped with coding. Remember that noone who contributed got paid for this, so feel free to leave a donation (and if you contributed and your donation address is not listed yet, please reach out)

@3DotsHub 0x05565A6DB79fD6904CdA9f2885D96a711c942424

@@samclassix addressToBeDefined
