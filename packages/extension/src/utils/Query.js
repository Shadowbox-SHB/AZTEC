import fetch from 'node-fetch';
import {
    errorLog,
} from '~utils/log';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export default async function Query({
    graphQLServerUrl,
    query,
    variables,
    retry = 3,
    retryDelay = 500,
}) {
    let data;
    try {
        const response = await fetch(graphQLServerUrl, {
            method: 'POST',
            body: JSON.stringify({
                query,
                variables,
            }),
            headers: {
                'Content-Type': 'application/json',
            },
        });

        const json = await response.json();
        let errors;
        ({
            data,
            errors,
        } = json || {});
        if (errors) {
            errorLog('Error fetching data from GraphQL server.', errors);
        }
    } catch (error) {
        if (retry > 0) {
            await sleep(retryDelay);

            data = await Query({
                query,
                variables,
                retry: retry - 1,
            });
        } else {
            errorLog('Fetch query from GraphQL server failed.', error);
        }
    }

    return data;
}