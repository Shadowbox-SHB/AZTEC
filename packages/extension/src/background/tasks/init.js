/* global chrome */
import {
    set,
    onIdle,
} from '~utils/storage';
import settings from '~background/utils/settings';
import SyncService from '~background/services/SyncService';
import domainModel from '../../database/models/domain';
import configureWeb3Networks from '~utils/configureWeb3Networks';
// import { runLoadingEventsTest } from './syncTest'


export default async function init() {
    if (process.env.NODE_ENV !== 'production') {
        // chrome.storage.local.clear();

        // comment it
        // await runLoadingEventsTest();

        await set({
            __providerUrl: 'ws://localhost:8545',
            __infuraProjectId: '',
        });
        await domainModel.set(
            {
                domain: window.location.origin,
            },
            {
                ignoreDuplicate: true,
            },
        );

        onIdle(
            async () => {
                await set({
                    __sync: 0,
                });
                console.log('--- database idle ---');
                chrome.storage.local.getBytesInUse(null, (bytes) => {
                    console.log('getBytesInUse', bytes);
                });
                chrome.storage.local.get(null, data => console.info(data));
            },
            {
                persistent: true,
            },
        );
    }

    SyncService.set({
        notesPerRequest: await settings('NOTES_PER_SYNC_REQUEST'),
        syncInterval: await settings('SYNC_INTERVAL'),
    });

    await configureWeb3Networks();
    console.log('____CONFIGURED');
}
