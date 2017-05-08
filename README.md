# Infusionsoft app2csv

This application is intended for transferring data from one Infusionsoft database to another.  It uses the API to pull data from the source app and to input a small set of data into the destination app, like custom fields, tags, and products.  The output will be CSV files that will be imported into the destination app, and they will contain the majority of the data from the source app.

There are 3 steps that are required for this import process.  Each subsequent step is dependent on the previous steps being completed.  The reason for the multiple step method is that the app2csv process will look for the old IDs that have been imported into custom fields and automatically do the ID matching on the backend.  The resulting CSV files that are download don't need any work done to import.  They are good to import as-is, because all of the necessary IDs should be correct.  

## Step 1

* Contacts
* Companies
* Tags
* Products

## Step 2

* Tags for Contacts
  * Dependent on Tags and Contacts
* Notes
  * Dependent on Contacts
* Tasks/Appointments
  * Dependent on Contacts
* Opportunities
  * Dependent on Contacts
* Orders (no items)
  * Dependent on Contacts
* Subscriptions
  * Dependent on Contacts, Products, and Credit Cards

## Step 3

* Order Items
  * Dependent on Orders (no items)
* Payments
  * Dependent on Orders (no items)
