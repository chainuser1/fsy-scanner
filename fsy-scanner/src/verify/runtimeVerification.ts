import { runMigrations } from '../db/migrations';
import { getSetting, setSetting } from '../db/appSettings';
import { enqueueTask, claimNextTask, completeTask } from '../db/syncQueue';
import { detectColMap } from '../sync/puller';
import { buildReceiptDocument } from '../print/receipt';
import { printReceipt } from '../print/printer';

export type VerificationCheck = {
  name: string;
  success: boolean;
  details?: string;
};

export async function runVerificationChecks(): Promise<VerificationCheck[]> {
  const results: VerificationCheck[] = [];

  // 1. Migrations
  try {
    await runMigrations();
    results.push({ name: 'Database migrations', success: true });
  } catch (error: any) {
    results.push({ name: 'Database migrations', success: false, details: error?.message ?? String(error) });
  }

  // 2. App settings persistence
  const verifyKey = 'verify_test_key';
  const verifyValue = `ok-${Date.now()}`;
  let originalPrinterAddress: string | null = null;
  try {
    originalPrinterAddress = await getSetting('printer_address');
    await setSetting(verifyKey, verifyValue);
    const loadedValue = await getSetting(verifyKey);
    if (loadedValue !== verifyValue) {
      throw new Error(`Expected ${verifyValue}, got ${String(loadedValue)}`);
    }
    results.push({ name: 'App settings persistence', success: true });
  } catch (error: any) {
    results.push({ name: 'App settings persistence', success: false, details: error?.message ?? String(error) });
  }

  // 3. Sync queue round-trip
  let tempTaskId: number | null = null;
  try {
    tempTaskId = await enqueueTask('mark_registered', {
      participantId: 'verify-check',
      sheetsRow: 0,
      registeredAt: Date.now(),
      registeredBy: 'verify',
    });
    const claimed = await claimNextTask();
    if (!claimed || claimed.id !== tempTaskId) {
      throw new Error('Failed to claim the verification task');
    }
    await completeTask(claimed.id);
    results.push({ name: 'Sync queue round-trip', success: true });
  } catch (error: any) {
    results.push({ name: 'Sync queue round-trip', success: false, details: error?.message ?? String(error) });
  }

  // 4. Column map detection logic
  try {
    const colMap = detectColMap([
      ['ID', 'Name', 'Table Number', 'Hotel Room Number', 'Registered', 'Registered At', 'Registered By'],
    ]);

    if (colMap.ID !== 0 || colMap.Name !== 1 || colMap['Registered By'] !== 6) {
      throw new Error('Column map indices do not match expected values');
    }

    results.push({ name: 'Column map detection', success: true });
  } catch (error: any) {
    results.push({ name: 'Column map detection', success: false, details: error?.message ?? String(error) });
  }

  // 5. Receipt generation
  try {
    const document = buildReceiptDocument({ full_name: 'Verify User', room_number: '101', table_number: 'A' }, 'FSY Verify');
    if (!Array.isArray(document) || document.length === 0) {
      throw new Error('Receipt document was not generated correctly');
    }
    results.push({ name: 'Receipt document generation', success: true });
  } catch (error: any) {
    results.push({ name: 'Receipt document generation', success: false, details: error?.message ?? String(error) });
  }

  // 6. Print path validation (no printer configured)
  try {
    await setSetting('printer_address', '');
    try {
      await printReceipt({ full_name: 'Verify User', room_number: '101', table_number: 'A' }, 'FSY Verify');
      results.push({ name: 'Print path validation', success: false, details: 'Expected error when printer is not configured' });
    } catch (printError: any) {
      if (String(printError.message).includes('No printer configured')) {
        results.push({ name: 'Print path validation', success: true });
      } else {
        results.push({ name: 'Print path validation', success: false, details: printError?.message ?? String(printError) });
      }
    }
  } catch (error: any) {
    results.push({ name: 'Print path validation', success: false, details: error?.message ?? String(error) });
  } finally {
    if (originalPrinterAddress !== null) {
      await setSetting('printer_address', originalPrinterAddress);
    }
  }

  return results;
}
