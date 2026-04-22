import { getValidToken } from '../auth/google';
import { getSetting } from '../db/appSettings';
import { claimNextTask, completeTask, failTask, getPendingCount } from '../db/syncQueue';
import { updateRegistrationRow, ColMapError } from './sheetsApi';
import { useAppStore } from '../store/useAppStore';

export async function pusher(): Promise<void> {
  const accessToken = await getValidToken();
  if (!accessToken) {
    throw new Error('Unable to acquire Google Sheets access token');
  }

  const sheetId = await getSetting('sheets_id');
  const tabName = await getSetting('sheets_tab');
  const colMapJson = await getSetting('col_map');

  if (!sheetId || !tabName || !colMapJson) {
    throw new Error('Missing sheet configuration or column map for pusher');
  }

  let colMap: Record<string, number>;
  try {
    colMap = JSON.parse(colMapJson);
  } catch (err) {
    throw new Error('Invalid col_map stored in app settings');
  }

  while (true) {
    const task = await claimNextTask();
    if (!task) {
      break;
    }

    let taskFailed = false;
    try {
      const payload = JSON.parse(task.payload);

      if (task.type !== 'mark_registered' && task.type !== 'mark_printed') {
        throw new Error(`Unsupported sync task type: ${task.type}`);
      }

      if (typeof payload.sheetsRow !== 'number') {
        throw new Error('Invalid task payload: sheetsRow is required');
      }

      if (task.type === 'mark_registered') {
        if (typeof payload.verifiedAt !== 'string' || !payload.registeredBy) {
          throw new Error('Invalid mark_registered payload');
        }

        await updateRegistrationRow(accessToken, sheetId, tabName, payload.sheetsRow, colMap, {
          registered: true,
          verifiedAt: payload.verifiedAt,
          registeredBy: payload.registeredBy,
        });
      } else {
        if (typeof payload.printedAt !== 'string' || !payload.registeredBy) {
          throw new Error('Invalid mark_printed payload');
        }

        await updateRegistrationRow(accessToken, sheetId, tabName, payload.sheetsRow, colMap, {
          printedAt: payload.printedAt,
          registeredBy: payload.registeredBy,
        });
      }

      await completeTask(task.id);
    } catch (error: any) {
      taskFailed = true;
      const message = error?.message ? String(error.message) : 'Unknown error';
      const previousAttempts = task.attempts;

      if (error instanceof ColMapError) {
        await failTask(task.id, message);
      } else if (error.name === 'RateLimitError') {
        await failTask(task.id, message);
        if (previousAttempts + 1 >= 10) {
          (useAppStore as any).getState().incrementFailedTaskCount();
        }
        throw error;
      } else if (error.name === 'AuthExpiredError') {
        await failTask(task.id, message);
        if (previousAttempts + 1 >= 10) {
          (useAppStore as any).getState().incrementFailedTaskCount();
        }
        throw error;
      } else {
        await failTask(task.id, message);
      }

      if (previousAttempts + 1 >= 10) {
        (useAppStore as any).getState().incrementFailedTaskCount();
      }
    } finally {
      if (!taskFailed) {
        const pendingCount = await getPendingCount();
        (useAppStore as any).getState().setPendingTaskCount(pendingCount);
      }
    }
  }

  const pendingCount = await getPendingCount();
  (useAppStore as any).getState().setPendingTaskCount(pendingCount);
}
