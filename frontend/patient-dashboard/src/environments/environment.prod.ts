// src/environments/environment.prod.ts
export const environment = {
  production: true,
  apiUrl: '',  // Resolved at runtime via nginx reverse proxy to internal ALB
};
