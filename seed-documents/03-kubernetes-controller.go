package controller

import (
	"context"
	"fmt"
	"reflect"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	webappv1 "github.com/example/webapp-operator/api/v1"
)

const (
	webAppFinalizer = "webapp.example.com/finalizer"
	defaultImage    = "nginx:1.21"
	defaultReplicas = int32(2)
	defaultPort     = int32(80)
)

// WebAppReconciler reconciles a WebApp object
type WebAppReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// +kubebuilder:rbac:groups=webapp.example.com,resources=webapps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=webapp.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=webapp.example.com,resources=webapps/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=configmaps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=networking.k8s.io,resources=ingresses,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=events,verbs=create;patch

func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Fetch the WebApp instance
	webApp := &webappv1.WebApp{}
	err := r.Get(ctx, req.NamespacedName, webApp)
	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("WebApp resource not found. Ignoring since object must be deleted")
			return ctrl.Result{}, nil
		}
		logger.Error(err, "Failed to get WebApp")
		return ctrl.Result{}, err
	}

	// Check if the WebApp instance is marked to be deleted
	if webApp.GetDeletionTimestamp() != nil {
		if controllerutil.ContainsFinalizer(webApp, webAppFinalizer) {
			if err := r.finalizeWebApp(ctx, webApp); err != nil {
				return ctrl.Result{}, err
			}

			controllerutil.RemoveFinalizer(webApp, webAppFinalizer)
			err := r.Update(ctx, webApp)
			if err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Add finalizer for this CR
	if !controllerutil.ContainsFinalizer(webApp, webAppFinalizer) {
		controllerutil.AddFinalizer(webApp, webAppFinalizer)
		err = r.Update(ctx, webApp)
		if err != nil {
			return ctrl.Result{}, err
		}
	}

	// Reconcile ConfigMap
	if err := r.reconcileConfigMap(ctx, webApp); err != nil {
		logger.Error(err, "Failed to reconcile ConfigMap")
		return ctrl.Result{}, err
	}

	// Reconcile Deployment
	if err := r.reconcileDeployment(ctx, webApp); err != nil {
		logger.Error(err, "Failed to reconcile Deployment")
		return ctrl.Result{}, err
	}

	// Reconcile Service
	if err := r.reconcileService(ctx, webApp); err != nil {
		logger.Error(err, "Failed to reconcile Service")
		return ctrl.Result{}, err
	}

	// Reconcile Ingress if enabled
	if webApp.Spec.Ingress != nil && webApp.Spec.Ingress.Enabled {
		if err := r.reconcileIngress(ctx, webApp); err != nil {
			logger.Error(err, "Failed to reconcile Ingress")
			return ctrl.Result{}, err
		}
	} else {
		// Delete Ingress if it exists but is no longer needed
		if err := r.deleteIngressIfExists(ctx, webApp); err != nil {
			logger.Error(err, "Failed to delete Ingress")
			return ctrl.Result{}, err
		}
	}

	// Update status
	if err := r.updateStatus(ctx, webApp); err != nil {
		logger.Error(err, "Failed to update WebApp status")
		return ctrl.Result{}, err
	}

	return ctrl.Result{RequeueAfter: time.Minute}, nil
}

func (r *WebAppReconciler) finalizeWebApp(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)
	logger.Info("Successfully finalized WebApp")
	r.Recorder.Event(webApp, corev1.EventTypeNormal, "Deleted", "WebApp successfully deleted")
	return nil
}

func (r *WebAppReconciler) reconcileConfigMap(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	configMap := &corev1.ConfigMap{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name + "-config", Namespace: webApp.Namespace}, configMap)

	desiredConfigMap := r.configMapForWebApp(webApp)

	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("Creating a new ConfigMap", "ConfigMap.Namespace", desiredConfigMap.Namespace, "ConfigMap.Name", desiredConfigMap.Name)
			err = r.Create(ctx, desiredConfigMap)
			if err != nil {
				return err
			}
			r.Recorder.Event(webApp, corev1.EventTypeNormal, "Created", fmt.Sprintf("Created ConfigMap %s", desiredConfigMap.Name))
			return nil
		}
		return err
	}

	// Update ConfigMap if needed
	if !reflect.DeepEqual(configMap.Data, desiredConfigMap.Data) {
		configMap.Data = desiredConfigMap.Data
		err = r.Update(ctx, configMap)
		if err != nil {
			return err
		}
		logger.Info("Updated ConfigMap", "ConfigMap.Namespace", configMap.Namespace, "ConfigMap.Name", configMap.Name)
		r.Recorder.Event(webApp, corev1.EventTypeNormal, "Updated", fmt.Sprintf("Updated ConfigMap %s", configMap.Name))
	}

	return nil
}

func (r *WebAppReconciler) reconcileDeployment(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	deployment := &appsv1.Deployment{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name, Namespace: webApp.Namespace}, deployment)

	desiredDeployment := r.deploymentForWebApp(webApp)

	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("Creating a new Deployment", "Deployment.Namespace", desiredDeployment.Namespace, "Deployment.Name", desiredDeployment.Name)
			err = r.Create(ctx, desiredDeployment)
			if err != nil {
				return err
			}
			r.Recorder.Event(webApp, corev1.EventTypeNormal, "Created", fmt.Sprintf("Created Deployment %s", desiredDeployment.Name))
			return nil
		}
		return err
	}

	// Check if update is needed
	needsUpdate := false

	if *deployment.Spec.Replicas != *desiredDeployment.Spec.Replicas {
		deployment.Spec.Replicas = desiredDeployment.Spec.Replicas
		needsUpdate = true
	}

	if deployment.Spec.Template.Spec.Containers[0].Image != desiredDeployment.Spec.Template.Spec.Containers[0].Image {
		deployment.Spec.Template.Spec.Containers[0].Image = desiredDeployment.Spec.Template.Spec.Containers[0].Image
		needsUpdate = true
	}

	if !reflect.DeepEqual(deployment.Spec.Template.Spec.Containers[0].Resources, desiredDeployment.Spec.Template.Spec.Containers[0].Resources) {
		deployment.Spec.Template.Spec.Containers[0].Resources = desiredDeployment.Spec.Template.Spec.Containers[0].Resources
		needsUpdate = true
	}

	if !reflect.DeepEqual(deployment.Spec.Template.Spec.Containers[0].Env, desiredDeployment.Spec.Template.Spec.Containers[0].Env) {
		deployment.Spec.Template.Spec.Containers[0].Env = desiredDeployment.Spec.Template.Spec.Containers[0].Env
		needsUpdate = true
	}

	if needsUpdate {
		err = r.Update(ctx, deployment)
		if err != nil {
			return err
		}
		logger.Info("Updated Deployment", "Deployment.Namespace", deployment.Namespace, "Deployment.Name", deployment.Name)
		r.Recorder.Event(webApp, corev1.EventTypeNormal, "Updated", fmt.Sprintf("Updated Deployment %s", deployment.Name))
	}

	return nil
}

func (r *WebAppReconciler) reconcileService(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	service := &corev1.Service{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name, Namespace: webApp.Namespace}, service)

	desiredService := r.serviceForWebApp(webApp)

	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("Creating a new Service", "Service.Namespace", desiredService.Namespace, "Service.Name", desiredService.Name)
			err = r.Create(ctx, desiredService)
			if err != nil {
				return err
			}
			r.Recorder.Event(webApp, corev1.EventTypeNormal, "Created", fmt.Sprintf("Created Service %s", desiredService.Name))
			return nil
		}
		return err
	}

	// Update Service if port changed
	if service.Spec.Ports[0].Port != desiredService.Spec.Ports[0].Port {
		service.Spec.Ports = desiredService.Spec.Ports
		err = r.Update(ctx, service)
		if err != nil {
			return err
		}
		logger.Info("Updated Service", "Service.Namespace", service.Namespace, "Service.Name", service.Name)
		r.Recorder.Event(webApp, corev1.EventTypeNormal, "Updated", fmt.Sprintf("Updated Service %s", service.Name))
	}

	return nil
}

func (r *WebAppReconciler) reconcileIngress(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	ingress := &networkingv1.Ingress{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name, Namespace: webApp.Namespace}, ingress)

	desiredIngress := r.ingressForWebApp(webApp)

	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("Creating a new Ingress", "Ingress.Namespace", desiredIngress.Namespace, "Ingress.Name", desiredIngress.Name)
			err = r.Create(ctx, desiredIngress)
			if err != nil {
				return err
			}
			r.Recorder.Event(webApp, corev1.EventTypeNormal, "Created", fmt.Sprintf("Created Ingress %s", desiredIngress.Name))
			return nil
		}
		return err
	}

	// Update Ingress if host changed
	if ingress.Spec.Rules[0].Host != desiredIngress.Spec.Rules[0].Host {
		ingress.Spec = desiredIngress.Spec
		err = r.Update(ctx, ingress)
		if err != nil {
			return err
		}
		logger.Info("Updated Ingress", "Ingress.Namespace", ingress.Namespace, "Ingress.Name", ingress.Name)
		r.Recorder.Event(webApp, corev1.EventTypeNormal, "Updated", fmt.Sprintf("Updated Ingress %s", ingress.Name))
	}

	return nil
}

func (r *WebAppReconciler) deleteIngressIfExists(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	ingress := &networkingv1.Ingress{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name, Namespace: webApp.Namespace}, ingress)
	if err != nil {
		if errors.IsNotFound(err) {
			return nil
		}
		return err
	}

	logger.Info("Deleting Ingress", "Ingress.Namespace", ingress.Namespace, "Ingress.Name", ingress.Name)
	err = r.Delete(ctx, ingress)
	if err != nil {
		return err
	}
	r.Recorder.Event(webApp, corev1.EventTypeNormal, "Deleted", fmt.Sprintf("Deleted Ingress %s", ingress.Name))
	return nil
}

func (r *WebAppReconciler) updateStatus(ctx context.Context, webApp *webappv1.WebApp) error {
	logger := log.FromContext(ctx)

	// Get the Deployment
	deployment := &appsv1.Deployment{}
	err := r.Get(ctx, types.NamespacedName{Name: webApp.Name, Namespace: webApp.Namespace}, deployment)
	if err != nil {
		if errors.IsNotFound(err) {
			return nil
		}
		return err
	}

	// Update status fields
	status := webappv1.WebAppStatus{
		AvailableReplicas: deployment.Status.AvailableReplicas,
		ReadyReplicas:     deployment.Status.ReadyReplicas,
		Replicas:          deployment.Status.Replicas,
	}

	// Determine conditions
	conditions := []metav1.Condition{}

	// Available condition
	availableCondition := metav1.Condition{
		Type:               "Available",
		LastTransitionTime: metav1.Now(),
	}
	if deployment.Status.AvailableReplicas >= *deployment.Spec.Replicas {
		availableCondition.Status = metav1.ConditionTrue
		availableCondition.Reason = "MinimumReplicasAvailable"
		availableCondition.Message = "Deployment has minimum availability"
	} else {
		availableCondition.Status = metav1.ConditionFalse
		availableCondition.Reason = "MinimumReplicasUnavailable"
		availableCondition.Message = "Deployment does not have minimum availability"
	}
	conditions = append(conditions, availableCondition)

	// Progressing condition
	progressingCondition := metav1.Condition{
		Type:               "Progressing",
		LastTransitionTime: metav1.Now(),
	}
	if deployment.Status.UpdatedReplicas == *deployment.Spec.Replicas {
		progressingCondition.Status = metav1.ConditionTrue
		progressingCondition.Reason = "NewReplicaSetAvailable"
		progressingCondition.Message = "Deployment has successfully progressed"
	} else {
		progressingCondition.Status = metav1.ConditionTrue
		progressingCondition.Reason = "ReplicaSetUpdated"
		progressingCondition.Message = "Deployment is progressing"
	}
	conditions = append(conditions, progressingCondition)

	status.Conditions = conditions

	// Calculate URL if Ingress is enabled
	if webApp.Spec.Ingress != nil && webApp.Spec.Ingress.Enabled {
		protocol := "http"
		if webApp.Spec.Ingress.TLS != nil && len(webApp.Spec.Ingress.TLS) > 0 {
			protocol = "https"
		}
		status.URL = fmt.Sprintf("%s://%s", protocol, webApp.Spec.Ingress.Host)
	}

	// Update if changed
	if !reflect.DeepEqual(webApp.Status, status) {
		webApp.Status = status
		err = r.Status().Update(ctx, webApp)
		if err != nil {
			logger.Error(err, "Failed to update WebApp status")
			return err
		}
		logger.Info("Updated WebApp status", "Status", status)
	}

	return nil
}

func (r *WebAppReconciler) configMapForWebApp(webApp *webappv1.WebApp) *corev1.ConfigMap {
	data := make(map[string]string)
	for key, value := range webApp.Spec.Config {
		data[key] = value
	}

	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webApp.Name + "-config",
			Namespace: webApp.Namespace,
			Labels:    labelsForWebApp(webApp.Name),
		},
		Data: data,
	}

	controllerutil.SetControllerReference(webApp, configMap, r.Scheme)
	return configMap
}

func (r *WebAppReconciler) deploymentForWebApp(webApp *webappv1.WebApp) *appsv1.Deployment {
	labels := labelsForWebApp(webApp.Name)

	replicas := defaultReplicas
	if webApp.Spec.Replicas != nil {
		replicas = *webApp.Spec.Replicas
	}

	image := defaultImage
	if webApp.Spec.Image != "" {
		image = webApp.Spec.Image
	}

	port := defaultPort
	if webApp.Spec.Port != 0 {
		port = webApp.Spec.Port
	}

	// Build environment variables
	var envVars []corev1.EnvVar
	for key, value := range webApp.Spec.Env {
		envVars = append(envVars, corev1.EnvVar{
			Name:  key,
			Value: value,
		})
	}

	// Add config map reference
	envVars = append(envVars, corev1.EnvVar{
		Name: "CONFIG_PATH",
		ValueFrom: &corev1.EnvVarSource{
			ConfigMapKeyRef: &corev1.ConfigMapKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{
					Name: webApp.Name + "-config",
				},
				Key:      "config.yaml",
				Optional: boolPtr(true),
			},
		},
	})

	// Build resource requirements
	resources := corev1.ResourceRequirements{
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("500m"),
			corev1.ResourceMemory: resource.MustParse("256Mi"),
		},
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("100m"),
			corev1.ResourceMemory: resource.MustParse("128Mi"),
		},
	}

	if webApp.Spec.Resources != nil {
		if webApp.Spec.Resources.Limits != nil {
			resources.Limits = webApp.Spec.Resources.Limits
		}
		if webApp.Spec.Resources.Requests != nil {
			resources.Requests = webApp.Spec.Resources.Requests
		}
	}

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webApp.Name,
			Namespace: webApp.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: labels,
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: labels,
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: webApp.Spec.ServiceAccountName,
					Containers: []corev1.Container{{
						Name:      "webapp",
						Image:     image,
						Ports: []corev1.ContainerPort{{
							ContainerPort: port,
							Name:          "http",
							Protocol:      corev1.ProtocolTCP,
						}},
						Env:       envVars,
						Resources: resources,
						LivenessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								HTTPGet: &corev1.HTTPGetAction{
									Path: "/healthz",
									Port: intstr.FromInt(int(port)),
								},
							},
							InitialDelaySeconds: 15,
							PeriodSeconds:       20,
							TimeoutSeconds:      5,
							FailureThreshold:    3,
						},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								HTTPGet: &corev1.HTTPGetAction{
									Path: "/ready",
									Port: intstr.FromInt(int(port)),
								},
							},
							InitialDelaySeconds: 5,
							PeriodSeconds:       10,
							TimeoutSeconds:      5,
							FailureThreshold:    3,
						},
						VolumeMounts: []corev1.VolumeMount{{
							Name:      "config",
							MountPath: "/etc/webapp",
							ReadOnly:  true,
						}},
					}},
					Volumes: []corev1.Volume{{
						Name: "config",
						VolumeSource: corev1.VolumeSource{
							ConfigMap: &corev1.ConfigMapVolumeSource{
								LocalObjectReference: corev1.LocalObjectReference{
									Name: webApp.Name + "-config",
								},
							},
						},
					}},
				},
			},
		},
	}

	// Add affinity if specified
	if webApp.Spec.Affinity != nil {
		deployment.Spec.Template.Spec.Affinity = webApp.Spec.Affinity
	}

	// Add tolerations if specified
	if webApp.Spec.Tolerations != nil {
		deployment.Spec.Template.Spec.Tolerations = webApp.Spec.Tolerations
	}

	// Add node selector if specified
	if webApp.Spec.NodeSelector != nil {
		deployment.Spec.Template.Spec.NodeSelector = webApp.Spec.NodeSelector
	}

	controllerutil.SetControllerReference(webApp, deployment, r.Scheme)
	return deployment
}

func (r *WebAppReconciler) serviceForWebApp(webApp *webappv1.WebApp) *corev1.Service {
	labels := labelsForWebApp(webApp.Name)

	port := defaultPort
	if webApp.Spec.Port != 0 {
		port = webApp.Spec.Port
	}

	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webApp.Name,
			Namespace: webApp.Namespace,
			Labels:    labels,
		},
		Spec: corev1.ServiceSpec{
			Type:     corev1.ServiceTypeClusterIP,
			Selector: labels,
			Ports: []corev1.ServicePort{{
				Port:       port,
				TargetPort: intstr.FromInt(int(port)),
				Protocol:   corev1.ProtocolTCP,
				Name:       "http",
			}},
		},
	}

	controllerutil.SetControllerReference(webApp, service, r.Scheme)
	return service
}

func (r *WebAppReconciler) ingressForWebApp(webApp *webappv1.WebApp) *networkingv1.Ingress {
	labels := labelsForWebApp(webApp.Name)

	port := defaultPort
	if webApp.Spec.Port != 0 {
		port = webApp.Spec.Port
	}

	pathType := networkingv1.PathTypePrefix

	ingress := &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:        webApp.Name,
			Namespace:   webApp.Namespace,
			Labels:      labels,
			Annotations: webApp.Spec.Ingress.Annotations,
		},
		Spec: networkingv1.IngressSpec{
			IngressClassName: webApp.Spec.Ingress.IngressClassName,
			Rules: []networkingv1.IngressRule{{
				Host: webApp.Spec.Ingress.Host,
				IngressRuleValue: networkingv1.IngressRuleValue{
					HTTP: &networkingv1.HTTPIngressRuleValue{
						Paths: []networkingv1.HTTPIngressPath{{
							Path:     "/",
							PathType: &pathType,
							Backend: networkingv1.IngressBackend{
								Service: &networkingv1.IngressServiceBackend{
									Name: webApp.Name,
									Port: networkingv1.ServiceBackendPort{
										Number: port,
									},
								},
							},
						}},
					},
				},
			}},
		},
	}

	// Add TLS if configured
	if webApp.Spec.Ingress.TLS != nil {
		ingress.Spec.TLS = webApp.Spec.Ingress.TLS
	}

	controllerutil.SetControllerReference(webApp, ingress, r.Scheme)
	return ingress
}

func labelsForWebApp(name string) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":       "webapp",
		"app.kubernetes.io/instance":   name,
		"app.kubernetes.io/managed-by": "webapp-operator",
	}
}

func boolPtr(b bool) *bool {
	return &b
}

// SetupWithManager sets up the controller with the Manager.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&webappv1.WebApp{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		Owns(&networkingv1.Ingress{}).
		Complete(r)
}
