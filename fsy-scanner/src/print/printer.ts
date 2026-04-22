import { ThermalPrinter } from '@finan-me/react-native-thermal-printer';
import { getSetting } from '../db/appSettings';
import { buildReceiptDocument } from './receipt';

export async function printReceipt(
  participant: { full_name?: string; room_number?: string | null; table_number?: string | null },
  eventName: string
): Promise<void> {
  const printerAddress = await getSetting('printer_address');
  if (!printerAddress) {
    throw new Error('No printer configured. Enter a Bluetooth printer address in Settings.');
  }

  const document = buildReceiptDocument(participant, eventName);
  const job = {
    printers: [
      {
        address: printerAddress,
        copies: 1,
        options: {
          paperWidthMm: 80,
          printerType: 'receipt',
          keepAlive: false,
        },
      },
    ],
    documents: [document],
    options: {
      continueOnError: false,
      onProgress: (completed: number, total: number) => {
        console.log(`Print progress ${completed} / ${total}`);
      },
      onJobComplete: (address: string, success: boolean, error?: { message?: string }) => {
        if (!success) {
          console.error(`Printer job failed for ${address}:`, error);
        }
      },
    },
  };

  const result = await ThermalPrinter.printReceipt(job as any);
  if (!result.success) {
    const printerResults = result.results as Map<string, { success: boolean; error?: { message?: string } }>;
    const printerErrors = Array.from(printerResults.entries())
      .filter(([, printerResult]) => !printerResult.success)
      .map(([address, printerResult]) => {
        const reason = printerResult.error?.message ?? 'unknown printer error';
        return `${address}: ${reason}`;
      });

    throw new Error(`Print failed: ${printerErrors.join('; ') || 'unknown printer error'}`);
  }
}
