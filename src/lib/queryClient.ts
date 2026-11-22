import { QueryClient } from '@tanstack/react-query';

// Central async-state client. Conservative defaults for a maintenance app:
// data is fresh for 30s, retries once (RLS/permission errors rarely recover
// from blind retries), and refetches on window focus for field technicians
// who switch between apps.
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 5 * 60_000,
      retry: 1,
      refetchOnWindowFocus: true,
    },
  },
});
