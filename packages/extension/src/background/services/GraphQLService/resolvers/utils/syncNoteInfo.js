import {
    get,
} from '~utils/storage';
import noteModel from '~database/models/note';
import SyncService from '~background/services/SyncService';

export default async function syncNoteInfo(noteId, ctx) {
    const {
        user: {
            address: userAddress,
        },
    } = ctx;

    let note = await noteModel.get({
        id: noteId,
    });
    let userKey;
    if (note) {
        userKey = await get(userAddress);
    }
    if (!note
        || note.owner !== userKey
    ) {
        note = await SyncService.syncNote({
            address: userAddress,
            noteId,
        });
    }

    return note;
}