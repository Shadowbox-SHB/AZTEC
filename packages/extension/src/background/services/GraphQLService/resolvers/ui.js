import fetchAsset from './utils/fetchAsset';
import fetchAztecAccount from './utils/fetchAztecAccount';
import mergeResolvers from './utils/mergeResolvers';
import ConnectionService from '~/ui/services/ConnectionService';
import Web3Service from '~/helpers/Web3Service';
import base from './base';

const uiResolvers = {
    Account: {
        linkedPublicKey: async ({ address, linkedPublicKey }) => linkedPublicKey
            || Web3Service
                .useContract('AccountRegistry')
                .method('accountMapping')
                .call(address),
    },
    Query: {
        user: async (_, { address }) => {
            const {
                account,
            } = await fetchAztecAccount({
                address,
            }) || {};
            return account;
        },
        asset: async (_, { id }) => {
            const {
                asset,
            } = await fetchAsset({
                address: id,
            });
            return asset;
        },
        account: async (_, { address }) => fetchAztecAccount({
            address,
        }),
        note: async (_, args) => {
            const {
                note,
            } = await ConnectionService.query({
                query: 'note',
                data: {
                    ...args,
                    requestedFields: `
                        noteHash
                        metadata
                        viewingKey
                        status
                        asset {
                            address
                        }
                    `,
                },
            });

            if (!note) {
                return null;
            }

            return {
                ...note,
                asset: note.asset.address,
            };
        },
    },
};

export default mergeResolvers(
    base,
    uiResolvers,
);
