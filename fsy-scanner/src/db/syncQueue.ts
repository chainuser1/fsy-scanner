// Sync queue stubs (placeholders)

export async function enqueueTask(type: 'mark_registered' | 'pull_delta', payload: object): Promise<number> {
  throw new Error('Not implemented');
}

export async function claimNextTask(): Promise<any | null> {
  throw new Error('Not implemented');
}

export async function completeTask(id: number): Promise<void> {
  throw new Error('Not implemented');
}

export async function failTask(id: number, error: string): Promise<void> {
  throw new Error('Not implemented');
}

export async function resetInProgressTasks(): Promise<void> {
  throw new Error('Not implemented');
}

export async function getPendingCount(): Promise<number> {
  throw new Error('Not implemented');
}
