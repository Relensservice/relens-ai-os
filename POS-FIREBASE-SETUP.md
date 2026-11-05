# ReLens POS — Firebase setup

This repository addition provides a first implementation of the ReLens integrated POS.

## Included
- `pos.html`: responsive staff POS with Firebase Authentication and Firestore.
- `firestore.rules`: staff-role based access rules; prescription documents are restricted to owner/admin/optician.
- `firebase.json`: Firebase Hosting and Firestore rules deployment configuration.

## Important: this is not connected to a Firebase project yet
The POS intentionally ships with placeholder Firebase web configuration. No Firebase credentials, service-account key, or owner password is included. Configure your own Firebase project before use.

## Setup
1. Create a Firebase project at https://console.firebase.google.com/ and register a Web App.
2. Enable **Authentication → Email/Password**. Do not enable public user registration.
3. Create the **Cloud Firestore** database in production mode.
4. Copy the Firebase Web App config into the `firebaseConfig` object near the top of the script in `pos.html`. The web config is a public client identifier; never paste service-account JSON or Admin SDK private keys into browser code.
5. Deploy rules: install Firebase CLI, run `firebase login`, select the project with `firebase use --add`, then run `firebase deploy --only firestore:rules`.
6. Create staff users in Firebase Authentication. Assign a custom claim using a trusted Admin SDK environment (Cloud Shell or a protected server), e.g. `{ role: "owner" }`. Never expose Admin SDK credentials in the website. Supported roles: owner, admin, manager, staff, optician.
7. Host the site over HTTPS. For Firebase Hosting, deploy from the configured hosting root. The POS is at `/pos.html`.

## Current working scope
- Email/password sign-in; checks the signed-in user's custom `role` claim.
- Dashboard metrics, inventory creation/search, customer creation/search, order list, and walk-in/website-origin POS sale recording.
- A sale uses a Firestore transaction to re-check stock, decrement stock, and create a sale record atomically.

## Before production / next implementation phase
- Add a trusted Cloud Function for order intake from the ReLens storefront, payment verification/webhooks, and idempotency.
- Use Cloud Functions/Admin SDK for atomic sale + stock writes with server-side role validation and immutable audit trail. Client-side Firestore transactions are a starter workflow, not a substitute for server-verified financial operations.
- Add a dedicated optical job workflow (pickup, frame inspection, prescription, lab order, edging, fitting, QC, dispatch, delivery), role-restricted prescription access and signed file URLs.
- Configure tax by item classification and CA/CGST/SGST/IGST rules with accountant review before tax invoices are issued.
- Add invoice PDF/thermal printing, returns/refunds, purchase receiving, supplier ledger, stock movement history, reconciliation, backup and monitoring.
- Configure Firestore App Check, MFA for privileged staff, least-privilege roles, security monitoring and backups.
- Online checkout must never mark an order paid based on browser input. Verify payment on the server using the payment provider webhook.

## Data collections
`products`, `sales`, `orders`, `customers`, `prescriptions`, `stockMovements`, `suppliers`, `expenses`, `settings`.

Do not store unnecessary health information. Treat prescription and contact details as sensitive customer data; limit access, retention and exports.
