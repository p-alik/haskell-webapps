{-# LANGUAGE Arrows                #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module TenantApi
  ( create_tenant
  , read_tenants
  , read_tenant_by_id
  , read_tenant_by_backofficedomain
  , remove_tenant
  , update_tenant
  , activate_tenant
  , deactivate_tenant
  ) where

import           Control.Arrow
import           Data.Text
import           Database.PostgreSQL.Simple (Connection)
import           DataTypes
import           GHC.Int
import           Opaleye
import           OpaleyeDef
import           RoleApi
import           UserApi

create_tenant :: Connection -> TenantIncoming -> IO (Maybe Tenant)
create_tenant conn tenant@Tenant {
  tenant_id = _
 ,tenant_name = name
 ,tenant_firstname = first_name
 ,tenant_lastname = last_name
 ,tenant_email = email
 ,tenant_phone = phone
 ,tenant_status = _
 ,tenant_ownerid = owner_id
 ,tenant_backofficedomain = bo_domain} = do
  tenants <- runInsertManyReturning conn tenantTable (return Tenant {
    tenant_id = Nothing
   ,tenant_name = pgStrictText name
   ,tenant_firstname = pgStrictText first_name
   ,tenant_lastname = pgStrictText last_name
   ,tenant_email = pgStrictText email
   ,tenant_phone = pgStrictText phone
   ,tenant_status = constant TenantStatusInActive
   ,tenant_ownerid = toNullable . constant <$> owner_id
   ,tenant_backofficedomain = pgStrictText bo_domain
  }) id
  return $ case tenants of
    []     -> Nothing
    (x:xs) ->Just x

activate_tenant :: Connection -> Tenant -> IO Tenant
activate_tenant conn tenant = set_tenant_status conn tenant TenantStatusActive

deactivate_tenant :: Connection -> Tenant -> IO Tenant
deactivate_tenant conn tenant = set_tenant_status conn tenant TenantStatusInActive

set_tenant_status :: Connection -> Tenant -> TenantStatus -> IO Tenant
set_tenant_status conn tenant status = update_tenant conn (tenant_id tenant)
                                              tenant { tenant_status = status }

update_tenant :: Connection -> TenantId -> Tenant -> IO Tenant
update_tenant conn t_tenantid tenant@Tenant {
  tenant_id = id
  ,tenant_name = name
  ,tenant_firstname = first_name
  ,tenant_lastname = last_name
  ,tenant_email = email
  ,tenant_phone = phone
  ,tenant_status = status
  ,tenant_ownerid = owner_id
  ,tenant_backofficedomain = bo_domain} = do
  runUpdate conn tenantTable update_func match_func
  return tenant
  where
    match_func :: TenantTableR -> Column PGBool
    match_func Tenant { tenant_id = id } = id .== (constant t_tenantid)
    update_func :: TenantTableR -> TenantTableW
    update_func x = Tenant {
      tenant_id = constant $ Just id
      ,tenant_name =  pgStrictText name
      ,tenant_firstname =  pgStrictText first_name
      ,tenant_lastname =  pgStrictText last_name
      ,tenant_email =  pgStrictText email
      ,tenant_phone =  pgStrictText phone
      ,tenant_status =  constant status
      ,tenant_ownerid =  toNullable . constant <$> owner_id
      ,tenant_backofficedomain =  pgStrictText bo_domain
    }

remove_tenant :: Connection -> Tenant -> IO GHC.Int.Int64
remove_tenant conn tenant@Tenant {tenant_id = tid} = do
  deactivate_tenant conn tenant
  update_tenant conn (tenant_id tenant) tenant { tenant_ownerid = Nothing }
  users_for_tenant <- read_users_for_tenant conn tid
  roles_for_tenant <- read_roles_for_tenant conn tid
  mapM_ (remove_role conn) roles_for_tenant
  mapM_ (remove_user conn) users_for_tenant
  runDelete conn tenantTable match_func
  where
    match_func :: TenantTableR -> Column PGBool
    match_func Tenant { tenant_id = id } = id .== (constant tid)

read_tenants :: Connection -> IO [Tenant]
read_tenants conn = runQuery conn tenant_query

read_tenant_by_id :: Connection -> TenantId -> IO (Maybe Tenant)
read_tenant_by_id conn id = do
  r <- runQuery conn $ (tenant_query_by_id id)
  return $ case r of
    []     -> Nothing
    (x:xs) -> Just x

read_tenant_by_backofficedomain :: Connection -> Text -> IO (Maybe Tenant)
read_tenant_by_backofficedomain conn domain = do
  r <- runQuery conn $ (tenant_query_by_backoffocedomain domain)
  return $ case r of
    []     -> Nothing
    (x:xs) -> Just x

tenant_query :: Opaleye.Query TenantTableR
tenant_query = queryTable tenantTable

tenant_query_by_id :: TenantId -> Opaleye.Query TenantTableR
tenant_query_by_id t_id = proc () -> do
  row@Tenant {tenant_id = id} <- tenant_query -< ()
  restrict -< id .== (constant t_id)
  returnA -< row

tenant_query_by_backoffocedomain :: Text -> Opaleye.Query TenantTableR
tenant_query_by_backoffocedomain domain = proc () -> do
  row@Tenant { tenant_backofficedomain = bo_domain } <- tenant_query -< ()
  restrict -< bo_domain .== (pgStrictText domain)
  returnA -< row
