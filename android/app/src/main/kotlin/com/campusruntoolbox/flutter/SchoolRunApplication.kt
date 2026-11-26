package com.campusruntoolbox.flutter

import android.app.Application
import com.baidu.location.LocationClient
import com.baidu.mapapi.CoordType
import com.baidu.mapapi.SDKInitializer

class SchoolRunApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SDKInitializer.setAgreePrivacy(this, true)
        LocationClient.setAgreePrivacy(true)
        SDKInitializer.setApiKey(BuildConfig.MAPS_API_KEY)
        runCatching {
            SDKInitializer.initialize(this)
            SDKInitializer.setCoordType(CoordType.BD09LL)
        }
    }
}