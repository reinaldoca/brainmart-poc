// src/app/core/guards/auth.guard.ts
//
// Route guard: redirects to login if user is not authenticated.
// Reads authentication state from AuthService (JWT cookie presence).

import { inject }        from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { AuthService }   from '../services/auth.service';

export const authGuard: CanActivateFn = () => {
  const auth   = inject(AuthService);
  const router = inject(Router);

  if (auth.isAuthenticated()) {
    return true;
  }
  return router.createUrlTree(['/login']);
};
