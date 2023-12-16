# dusd-lock-bot

sample implementation how the DUSD LOCK could be implemented.

DUSD locks provide the possibility for users to lock away their DUSD for a defined period of time and receive rewards in DUSD. Rewards are added from outside. This can be done by anyone who wants to increase incentives, but will mainly be done by a native bot that converts unused block rewards from native emissions to DUSD and adds it as rewards to the SC.

Each lockup is locked for the defined period after the deposit. So they won't get free all at once but according to the time they got added. later deposits will get freed later.

Rewards are always claimable.

## DUSD Lock as "NFT"

Ownership of a batch in the lock is defined via ERC721 Token. All data regarding the batch (lockedUntil, claimable rewards, amount...) can be queried from the SC. Be aware that transfering the token also transfer the right on claiming rewards (including all pending rewards on that token)
